//
//  Connection.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Connection.h"
#import "Utils.h"

#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>
#include <stdatomic.h>
#include "../../libs/tracy/public/tracy/TracyC.h"

#include "Limelight.h"

@implementation Connection {
    SERVER_INFORMATION _serverInfo;
    STREAM_CONFIGURATION _streamConfig;
    CONNECTION_LISTENER_CALLBACKS _clCallbacks;
    DECODER_RENDERER_CALLBACKS _drCallbacks;
    AUDIO_RENDERER_CALLBACKS _arCallbacks;
    char _hostString[256];
    char _appVersionString[32];
    char _gfeVersionString[32];
    char _rtspSessionUrl[128];
}

static NSLock* initLock;
static id<ConnectionCallbacks> _callbacks;
static int lastFrameNumber;
static int activeVideoFormat;
static video_stats_t currentVideoStats;
static video_stats_t lastVideoStats;
static NSLock* videoStatsLock;

// Audio (replaced SDL with AVAudioEngine)
static AVAudioEngine *audioEngine = nil;
static AVAudioPlayerNode *playerNode = nil;
static AVAudioConverter* audioConverter = nil;
static AVAudioFormat *inputOpusFormat = nil;
static AVAudioFormat *outputPcmFormat = nil;
static OPUS_MULTISTREAM_CONFIGURATION audioConfig;
static atomic_int queuePackets = 0;

static AVAudioCompressedBuffer *opusCompressedBuffer = nil;

static VideoDecoderRenderer* renderer;

int DrDecoderSetup(int videoFormat, int width, int height, int redrawRate, void* context, int drFlags)
{
    [renderer setupWithVideoFormat:videoFormat width:width height:height frameRate:redrawRate];
    lastFrameNumber = 0;
    activeVideoFormat = videoFormat;
    memset(&currentVideoStats, 0, sizeof(currentVideoStats));
    memset(&lastVideoStats, 0, sizeof(lastVideoStats));
    return 0;
}

void DrStart(void)
{
    [renderer start];
}

void DrStartForPushMode(void)
{
    [renderer startForPushMode];
}

void DrStop(void)
{
    [renderer stop];
}

-(BOOL) getVideoStats:(video_stats_t*)stats
{
    // We return lastVideoStats because it is a complete 1 second window
    [videoStatsLock lock];
    if (lastVideoStats.endTime != 0) {
        memcpy(stats, &lastVideoStats, sizeof(*stats));
        [videoStatsLock unlock];
        return YES;
    }
    
    // No stats yet
    [videoStatsLock unlock];
    return NO;
}

-(NSString*) getActiveCodecName
{
    switch (activeVideoFormat)
    {
        case VIDEO_FORMAT_H264:
            return @"H.264";
        case VIDEO_FORMAT_H265:
            return @"HEVC";
        case VIDEO_FORMAT_H265_MAIN10:
            if (LiGetCurrentHostDisplayHdrMode()) {
                return @"HEVC Main 10 HDR";
            }
            else {
                return @"HEVC Main 10 SDR";
            }
        case VIDEO_FORMAT_AV1_MAIN8:
            return @"AV1";
        case VIDEO_FORMAT_AV1_MAIN10:
            if (LiGetCurrentHostDisplayHdrMode()) {
                return @"AV1 10-bit HDR";
            }
            else {
                return @"AV1 10-bit SDR";
            }
        default:
            return @"UNKNOWN";
    }
}

int DrSubmitDecodeUnit(PDECODE_UNIT decodeUnit)
{
    TracyCZoneN(ctx, "DrSubmitDecodeUnit", true);
    int offset = 0;
    int ret;
    unsigned char* data = (unsigned char*) malloc(decodeUnit->fullLength);
    if (data == NULL) {
        TracyCZoneEnd(ctx);
        // A frame was lost due to OOM condition
        return DR_NEED_IDR;
    }
    
    CFTimeInterval now = CACurrentMediaTime();
    if (!lastFrameNumber) {
        currentVideoStats.startTime = now;
        lastFrameNumber = decodeUnit->frameNumber;
    }
    else {
        // Flip stats roughly every second
        if (now - currentVideoStats.startTime >= 1.0f) {
            currentVideoStats.endTime = now;
            
            [videoStatsLock lock];
            lastVideoStats = currentVideoStats;
            [videoStatsLock unlock];
            
            memset(&currentVideoStats, 0, sizeof(currentVideoStats));
            currentVideoStats.startTime = now;
        }
        
        // Any frame number greater than m_LastFrameNumber + 1 represents a dropped frame
        currentVideoStats.networkDroppedFrames += decodeUnit->frameNumber - (lastFrameNumber + 1);
        currentVideoStats.totalFrames += decodeUnit->frameNumber - (lastFrameNumber + 1);
        lastFrameNumber = decodeUnit->frameNumber;
    }
    
    if (decodeUnit->frameHostProcessingLatency != 0) {
        if (currentVideoStats.minHostProcessingLatency == 0 || decodeUnit->frameHostProcessingLatency < currentVideoStats.minHostProcessingLatency) {
            currentVideoStats.minHostProcessingLatency = decodeUnit->frameHostProcessingLatency;
        }
        
        if (decodeUnit->frameHostProcessingLatency > currentVideoStats.maxHostProcessingLatency) {
            currentVideoStats.maxHostProcessingLatency = decodeUnit->frameHostProcessingLatency;
        }
        
        currentVideoStats.framesWithHostProcessingLatency++;
        currentVideoStats.totalHostProcessingLatency += decodeUnit->frameHostProcessingLatency;
    }
    
    currentVideoStats.receivedFrames++;
    currentVideoStats.totalFrames++;

    PLENTRY entry = decodeUnit->bufferList;
    while (entry != NULL) {
        // Submit parameter set NALUs directly since no copy is required by the decoder
        if (entry->bufferType != BUFFER_TYPE_PICDATA) {
            ret = [renderer submitDecodeBuffer:(unsigned char*)entry->data
                                        length:entry->length
                                    bufferType:entry->bufferType
                                     decodeUnit:decodeUnit];
            if (ret != DR_OK) {
                free(data);
                TracyCZoneEnd(ctx);
                return ret;
            }
        }
        else {
            memcpy(&data[offset], entry->data, entry->length);
            offset += entry->length;
        }

        entry = entry->next;
    }

    // This function will take our picture data buffer
    ret = [renderer submitDecodeBuffer:data
                                length:offset
                            bufferType:BUFFER_TYPE_PICDATA
                            decodeUnit:decodeUnit];
    TracyCFrameMarkNamed("VideoFrame");
    TracyCZoneEnd(ctx);
    return ret;
}

int ArInit(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION opusConfig, void* context, int flags)
{
    
    // Prepare AVAudioSession
    NSError *error = nil;
    // Audio Session
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:&error]) {
        Log(LOG_E, @"Failed to set audio session: %@", error);
        return -1;
    }
    double preferredRate = opusConfig->sampleRate;
    if (![session setPreferredSampleRate:preferredRate error:&error]) {
        Log(LOG_E, @"Failed to set preferred sample rate: %@", error);
        return -1;
    }

    if (![session setActive:YES error:&error]) {
        Log(LOG_E, @"Failed to activate audio session: %@", error);
        return -1;
    }
    
    // Create engine and player node
    audioEngine = [[AVAudioEngine alloc] init];
    playerNode = [[AVAudioPlayerNode alloc] init];
    [audioEngine attachNode:playerNode];

    outputPcmFormat =[[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                  sampleRate:opusConfig->sampleRate
                                                    channels:opusConfig->channelCount
                                                 interleaved:NO];
    if ( !outputPcmFormat) {
        Log(LOG_E, @"Failed to create audio format");
        ArCleanup();
        return -1;
    }
    // Create compressed Opus AVAudioFormat (kAudioFormatOpus)
    AudioStreamBasicDescription opusDesc = {
        .mSampleRate       = (Float64)opusConfig->sampleRate,
        .mFormatID         = kAudioFormatOpus,
        .mFormatFlags      = 0,
        .mBytesPerPacket   = 0,
        .mFramesPerPacket  = (UInt32)opusConfig->samplesPerFrame,
        .mBytesPerFrame    = 0, //variable size
        .mChannelsPerFrame = (UInt32)opusConfig->channelCount,
        .mBitsPerChannel   = 0,
        .mReserved         = 0
    };

    inputOpusFormat = [[AVAudioFormat alloc] initWithStreamDescription:&opusDesc];
    if (!inputOpusFormat) {
        Log(LOG_E, @"Failed to create Opus AVAudioFormat (kAudioFormatOpus)");
        ArCleanup();
        return -1;
    }
    // Create converter from int16(interleaved) -> float32(non-interleaved)
    audioConverter = [[AVAudioConverter alloc] initFromFormat:inputOpusFormat toFormat:outputPcmFormat];
    if (!audioConverter) {
        Log(LOG_E, @"Failed to create AVAudioConverter");
        ArCleanup();
        return -1;
    }
    
    @try{
        [audioEngine connect:playerNode to:audioEngine.mainMixerNode format:outputPcmFormat];
    } @catch (NSException *e) {
        Log(LOG_E, @"Failed to connect playerNode: %@", e);
        ArCleanup();
        return -1;
    }
    
    NSError *errEngine = nil;
    if (![audioEngine startAndReturnError:&errEngine]) {
        Log(LOG_E, @"Failed to start AVAudioEngine: %@", errEngine);
        ArCleanup();
        return -1;
    }
    
    // Keep opus decoder and buffers
    audioConfig = *opusConfig;

    // Start playback
    [playerNode play];
    
    // Initialize queuedFrames
    atomic_store(&queuePackets, 0);
    
    return 0;
}

void ArCleanup(void)
{
    
    if (playerNode != nil) {
        @try {
            [playerNode stop];
            if (audioEngine != nil){
                [audioEngine detachNode:playerNode];
            }
        } @catch (...) {}
        playerNode = nil;
    }
    
    if (audioEngine != nil) {
        @try {
            [audioEngine stop];
        } @catch (...) {}
        audioEngine = nil;
    }
    
    inputOpusFormat = nil;
    outputPcmFormat = nil;
    
    audioConverter = nil;
    
    atomic_store(&queuePackets, 0);
    
    // Deactivate session optionally (keep active for faster restart in some use-cases)
    // [[AVAudioSession sharedInstance] setActive:NO error:nil];
}

void ArDecodeAndPlaySample(char* sampleData, int sampleLength)
{
    if(sampleLength == 0){
        return;
    }
    // Don't queue if there's already more than 30 ms of audio data waiting
    if (LiGetPendingAudioDuration() > 30) {
        return;
    }

    if(!opusCompressedBuffer || opusCompressedBuffer.maximumPacketSize < sampleLength){
        opusCompressedBuffer = [[AVAudioCompressedBuffer alloc]
         initWithFormat:inputOpusFormat
         packetCapacity:1
         maximumPacketSize:sampleLength];
        if (!opusCompressedBuffer) {
            Log(LOG_E, @"Failed to create AVAudioCompressedBuffer");
            return;
        }
    }
    opusCompressedBuffer.packetCount = 1;
    if (opusCompressedBuffer.packetDescriptions != NULL) {
        opusCompressedBuffer.packetDescriptions[0].mStartOffset = 0;
        opusCompressedBuffer.packetDescriptions[0].mDataByteSize = (UInt32)sampleLength;
        opusCompressedBuffer.packetDescriptions[0].mVariableFramesInPacket = (UInt32)audioConfig.samplesPerFrame;
    }
    
    memcpy(opusCompressedBuffer.data, sampleData, sampleLength);
    opusCompressedBuffer.byteLength = sampleLength;

    AVAudioPCMBuffer *pcmOut = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outputPcmFormat frameCapacity:audioConfig.samplesPerFrame];
    if (pcmOut == nil) {
        Log(LOG_E, @"Failed to create output AVAudioPCMBuffer");
        return;
    }

    NSError *convertError = nil;
    __block int8_t pendingPacket = 1;
    AVAudioConverterInputBlock inputBlock = ^AVAudioBuffer* (AVAudioPacketCount inNumPackets, AVAudioConverterInputStatus *outStatus) {
        if(pendingPacket > 0){
            *outStatus = AVAudioConverterInputStatus_HaveData;
            pendingPacket--;
            return opusCompressedBuffer;
        }else{
            *outStatus = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }
    };

    AVAudioConverterOutputStatus status =  [audioConverter convertToBuffer:pcmOut error:&convertError withInputFromBlock:inputBlock];

    if (status == AVAudioConverterOutputStatus_Error) {
        Log(LOG_E,@"[PcmPlayer] Audio conversion failed with status %ld error: %@", (long)status, convertError.localizedDescription);
        return;
    }else if(pcmOut.frameLength == 0){
        return;
    }

    // Backpressure: ensure we don't queue too many buffers locally
    while ((atomic_load(&queuePackets)) > 20) {
        usleep(1000);
    }

    // Schedule the converted buffer (float non-interleaved) on the player node
    atomic_fetch_add(&queuePackets, 1);
    [playerNode scheduleBuffer:pcmOut completionHandler:^{
        atomic_fetch_sub(&queuePackets, 1);
    }];
}

void ClStageStarting(int stage)
{
    [_callbacks stageStarting:LiGetStageName(stage)];
}

void ClStageComplete(int stage)
{
    [_callbacks stageComplete:LiGetStageName(stage)];
}

void ClStageFailed(int stage, int errorCode)
{
    [_callbacks stageFailed:LiGetStageName(stage) withError:errorCode portTestFlags:LiGetPortFlagsFromStage(stage)];
}

void ClConnectionStarted(void)
{
    [_callbacks connectionStarted];
}

void ClConnectionTerminated(int errorCode)
{
    [_callbacks connectionTerminated: errorCode];
}

void ClLogMessage(const char* format, ...)
{
    va_list va;
    va_start(va, format);
    vfprintf(stderr, format, va);
    va_end(va);
}

void ClRumble(unsigned short controllerNumber, unsigned short lowFreqMotor, unsigned short highFreqMotor)
{
    [_callbacks rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

void ClConnectionStatusUpdate(int status)
{
    [_callbacks connectionStatusUpdate:status];
}

void ClSetHdrMode(bool enabled)
{
    [renderer setHdrMode:enabled];
    [_callbacks setHdrMode:enabled];
}

void ClRumbleTriggers(uint16_t controllerNumber, uint16_t leftTriggerMotor, uint16_t rightTriggerMotor)
{
    [_callbacks rumbleTriggers:controllerNumber leftTrigger:leftTriggerMotor rightTrigger:rightTriggerMotor];
}

void ClSetMotionEventState(uint16_t controllerNumber, uint8_t motionType, uint16_t reportRateHz)
{
    [_callbacks setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

void ClSetControllerLED(uint16_t controllerNumber, uint8_t r, uint8_t g, uint8_t b)
{
    [_callbacks setControllerLed:controllerNumber r:r g:g b:b];
}

-(void) terminate
{
    // Interrupt any action blocking LiStartConnection(). This is
    // thread-safe and done outside initLock on purpose, since we
    // won't be able to acquire it if LiStartConnection is in
    // progress.
    LiInterruptConnection();
    
    // We dispatch this async to get out because this can be invoked
    // on a thread inside common and we don't want to deadlock. It also avoids
    // blocking on the caller's thread waiting to acquire initLock.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [initLock lock];
        LiStopConnection();
        [initLock unlock];
    });
}

-(id) initWithConfig:(StreamConfiguration*)config renderer:(VideoDecoderRenderer*)myRenderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks
{
    self = [super init];

    // Use a lock to ensure that only one thread is initializing
    // or deinitializing a connection at a time.
    if (initLock == nil) {
        initLock = [[NSLock alloc] init];
    }
    
    if (videoStatsLock == nil) {
        videoStatsLock = [[NSLock alloc] init];
    }
    
    NSString *rawAddress = [Utils addressPortStringToAddress:config.host];
    strncpy(_hostString,
            [rawAddress cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_hostString) - 1);
    strncpy(_appVersionString,
            [config.appVersion cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_appVersionString) - 1);
    if (config.gfeVersion != nil) {
        strncpy(_gfeVersionString,
                [config.gfeVersion cStringUsingEncoding:NSUTF8StringEncoding],
                sizeof(_gfeVersionString) - 1);
    }
    if (config.rtspSessionUrl != nil) {
        strncpy(_rtspSessionUrl,
                [config.rtspSessionUrl cStringUsingEncoding:NSUTF8StringEncoding],
                sizeof(_rtspSessionUrl) - 1);
    }

    LiInitializeServerInformation(&_serverInfo);
    _serverInfo.address = _hostString;
    _serverInfo.serverInfoAppVersion = _appVersionString;
    if (config.gfeVersion != nil) {
        _serverInfo.serverInfoGfeVersion = _gfeVersionString;
    }
    if (config.rtspSessionUrl != nil) {
        _serverInfo.rtspSessionUrl = _rtspSessionUrl;
    }
    _serverInfo.serverCodecModeSupport = config.serverCodecModeSupport;

    renderer = myRenderer;
    _callbacks = callbacks;

    LiInitializeStreamConfiguration(&_streamConfig);
    _streamConfig.width = config.width;
    _streamConfig.height = config.height;
    _streamConfig.fps = config.frameRate;
    _streamConfig.bitrate = config.bitRate;
    _streamConfig.supportedVideoFormats = config.supportedVideoFormats;
    _streamConfig.audioConfiguration = config.audioConfiguration;
    
    _streamConfig.colorSpace = COLORSPACE_REC_709;
    _streamConfig.colorRange = COLOR_RANGE_FULL;
    
    // Since we require iOS 12 or above, we're guaranteed to be running
    // on a 64-bit device with ARMv8 crypto instructions, so we don't
    // need to check for that here.
    _streamConfig.encryptionFlags = ENCFLG_ALL;
    
    if ([Utils isActiveNetworkVPN]) {
        // Force remote streaming mode when a VPN is connected
        _streamConfig.streamingRemotely = STREAM_CFG_REMOTE;
        _streamConfig.packetSize = 1024;
    }
    else {
        // Detect remote streaming automatically based on the IP address of the target
        _streamConfig.streamingRemotely = STREAM_CFG_AUTO;
        _streamConfig.packetSize = 1392;
    }

    memcpy(_streamConfig.remoteInputAesKey, [config.riKey bytes], [config.riKey length]);
    memset(_streamConfig.remoteInputAesIv, 0, 16);
    int riKeyId = htonl(config.riKeyId);
    memcpy(_streamConfig.remoteInputAesIv, &riKeyId, sizeof(riKeyId));

    LiInitializeVideoCallbacks(&_drCallbacks);
    _drCallbacks.setup = DrDecoderSetup;
    
    _drCallbacks.stop = DrStop;
    _drCallbacks.capabilities = CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1;
    switch (config.videoRendererMode) {
        case VideoRendererModeDirectPush:
            _drCallbacks.capabilities |= CAPABILITY_DIRECT_SUBMIT;
            // intentional fallthrough
        case VideoRendererModePush:
            _drCallbacks.start = DrStartForPushMode;
            _drCallbacks.submitDecodeUnit = DrSubmitDecodeUnit;
            break;
        case VideoRendererModePull:
            _drCallbacks.capabilities |= CAPABILITY_PULL_RENDERER;
            _drCallbacks.start = DrStart;
            break;
        default:
            NSAssert(false, @"invalid videoRendererMode");
            break;
    }

    LiInitializeAudioCallbacks(&_arCallbacks);
    _arCallbacks.init = ArInit;
    _arCallbacks.cleanup = ArCleanup;
    _arCallbacks.decodeAndPlaySample = ArDecodeAndPlaySample;
    _arCallbacks.capabilities = CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION;

    LiInitializeConnectionCallbacks(&_clCallbacks);
    _clCallbacks.stageStarting = ClStageStarting;
    _clCallbacks.stageComplete = ClStageComplete;
    _clCallbacks.stageFailed = ClStageFailed;
    _clCallbacks.connectionStarted = ClConnectionStarted;
    _clCallbacks.connectionTerminated = ClConnectionTerminated;
    _clCallbacks.logMessage = ClLogMessage;
    _clCallbacks.rumble = ClRumble;
    _clCallbacks.connectionStatusUpdate = ClConnectionStatusUpdate;
    _clCallbacks.setHdrMode = ClSetHdrMode;
    _clCallbacks.rumbleTriggers = ClRumbleTriggers;
    _clCallbacks.setMotionEventState = ClSetMotionEventState;
    _clCallbacks.setControllerLED = ClSetControllerLED;

    return self;
}

-(void) main
{
    [initLock lock];
    LiStartConnection(&_serverInfo,
                      &_streamConfig,
                      &_clCallbacks,
                      &_drCallbacks,
                      &_arCallbacks,
                      NULL, 0,
                      NULL, 0);
    [initLock unlock];
}

@end
