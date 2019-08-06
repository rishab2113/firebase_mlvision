#import "FirebaseMlVisionPlugin.h"
#import "FirebaseCam.h"

static FlutterError *getFlutterError(NSError *error) {
    return [FlutterError errorWithCode:[NSString stringWithFormat:@"Error %d", (int)error.code]
                               message:error.domain
                               details:error.localizedDescription];
}

@interface FLTFirebaseMlVisionPlugin ()
@property(readonly, nonatomic) NSObject<FlutterTextureRegistry> *registry;
@property(readonly, nonatomic) NSObject<FlutterBinaryMessenger> *messenger;
@property(readonly, nonatomic) FirebaseCam *camera;
@end

@implementation FLTFirebaseMlVisionPlugin {
    dispatch_queue_t _dispatchQueue;
}

static NSMutableDictionary<NSNumber *, id<Detector>> *detectors;

+ (void)handleError:(NSError *)error result:(FlutterResult)result {
    result(getFlutterError(error));
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    detectors = [NSMutableDictionary new];
    FlutterMethodChannel *channel =
    [FlutterMethodChannel methodChannelWithName:@"plugins.flutter.io/firebase_mlvision"
                                binaryMessenger:[registrar messenger]];
    FLTFirebaseMlVisionPlugin *instance = [[FLTFirebaseMlVisionPlugin alloc] initWithRegistry:[registrar textures]
                                                                                    messenger:[registrar messenger]];
    [registrar addMethodCallDelegate:instance channel:channel];
    
    SEL sel = NSSelectorFromString(@"registerLibrary:withVersion:");
    if ([FIRApp respondsToSelector:sel]) {
        [FIRApp performSelector:sel withObject:LIBRARY_NAME withObject:LIBRARY_VERSION];
    }
}

- (instancetype)initWithRegistry:(NSObject<FlutterTextureRegistry> *)registry
                       messenger:(NSObject<FlutterBinaryMessenger> *)messenger{
    self = [super init];
    if (self) {
        if (![FIRApp appNamed:@"__FIRAPP_DEFAULT"]) {
            NSLog(@"Configuring the default Firebase app...");
            [FIRApp configure];
            NSLog(@"Configured the default Firebase app %@.", [FIRApp defaultApp].name);
            _registry = registry;
            _messenger = messenger;
        }
    }
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (_dispatchQueue == nil) {
        _dispatchQueue = dispatch_queue_create("io.flutter.camera.dispatchqueue", NULL);
    }
    
    // Invoke the plugin on another dispatch queue to avoid blocking the UI.
    dispatch_async(_dispatchQueue, ^{
        [self handleMethodCallAsync:call result:result];
    });
}

- (void)handleMethodCallAsync:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSString *modelName = call.arguments[@"model"];
    NSDictionary *options = call.arguments[@"options"];
    NSNumber *handle = call.arguments[@"handle"];
    if ([@"ModelManager#setupLocalModel" isEqualToString:call.method]) {
        [SetupLocalModel modelName:modelName result:result];
    } else if ([@"ModelManager#setupRemoteModel" isEqualToString:call.method]) {
        [SetupRemoteModel modelName:modelName result:result];
    } else if ([@"camerasAvailable" isEqualToString:call.method]){
        AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
                                                             discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                                                             mediaType:AVMediaTypeVideo
                                                             position:AVCaptureDevicePositionUnspecified];
        NSArray<AVCaptureDevice *> *devices = discoverySession.devices;
        NSMutableArray<NSDictionary<NSString *, NSObject *> *> *reply =
        [[NSMutableArray alloc] initWithCapacity:devices.count];
        for (AVCaptureDevice *device in devices) {
            NSString *lensFacing;
            switch ([device position]) {
                case AVCaptureDevicePositionBack:
                    lensFacing = @"back";
                    break;
                case AVCaptureDevicePositionFront:
                    lensFacing = @"front";
                    break;
                case AVCaptureDevicePositionUnspecified:
                    lensFacing = @"external";
                    break;
            }
            [reply addObject:@{
                @"name" : [device uniqueID],
                @"lensFacing" : lensFacing,
                @"sensorOrientation" : @90,
            }];
        }
        result(reply);
    } else if ([@"initialize" isEqualToString:call.method]) {
        NSString *cameraName = call.arguments[@"cameraName"];
        NSString *resolutionPreset = call.arguments[@"resolutionPreset"];
        NSError *error;
        FirebaseCam *cam = [[FirebaseCam alloc] initWithCameraName:cameraName
                                                  resolutionPreset:resolutionPreset
                                                     dispatchQueue:_dispatchQueue
                                                             error:&error];
        if (error) {
            result(getFlutterError(error));
        } else {
            if (_camera) {
                [_camera close];
            }
            int64_t textureId = [_registry registerTexture:cam];
            _camera = cam;
            cam.onFrameAvailable = ^{
                [self->_registry textureFrameAvailable:textureId];
            };
            FlutterEventChannel *eventChannel = [FlutterEventChannel
                                                 eventChannelWithName:[NSString
                                                                       stringWithFormat:@"plugins.flutter.io/firebase_mlvision%lld",
                                                                       textureId]
                                                 binaryMessenger:_messenger];
            [eventChannel setStreamHandler:cam];
            cam.eventChannel = eventChannel;
            result(@{
                @"textureId" : @(textureId),
                @"previewWidth" : @(cam.previewSize.width),
                @"previewHeight" : @(cam.previewSize.height),
            });
            [cam start];
        }
    } else if ([@"BarcodeDetector#startDetection" isEqualToString:call.method] ||
               [@"FaceDetector#startDetection" isEqualToString:call.method] ||
               [@"ImageLabeler#startDetection" isEqualToString:call.method] ||
               [@"TextRecognizer#startDetection" isEqualToString:call.method] ||
               [@"VisionEdgeImageLabeler#startLocalDetection" isEqualToString:call.method] ||
               [@"VisionEdgeImageLabeler#startRemoteDetection" isEqualToString:call.method]){
        id<Detector> detector = detectors[handle];
        if (!detector) {
            detector = [[BarcodeDetector alloc] initWithVision:[FIRVision vision] options:options];
            [FLTFirebaseMlVisionPlugin addDetector:handle detector:detector];
        }
        _camera.activeDetector = detectors[handle];
        result(nil);
    } else if ([@"BarcodeDetector#close" isEqualToString:call.method] ||
               [@"FaceDetector#close" isEqualToString:call.method] ||
               [@"ImageLabeler#close" isEqualToString:call.method] ||
               [@"TextRecognizer#close" isEqualToString:call.method] ||
               [@"VisionEdgeImageLabeler#close" isEqualToString:call.method]) {
        NSNumber *handle = call.arguments[@"handle"];
        [detectors removeObjectForKey:handle];
        result(nil);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)handleDetection:(FlutterMethodCall *)call result:(FlutterResult)result {
    FIRVisionImage *image = [self dataToVisionImage:call.arguments];
    NSDictionary *options = call.arguments[@"options"];
    NSNumber *handle = call.arguments[@"handle"];
    id<Detector> detector = detectors[handle];
    if (!detector) {
        if ([call.method hasPrefix:@"BarcodeDetector"]) {
            detector = [[BarcodeDetector alloc] initWithVision:[FIRVision vision] options:options];
        } else if ([call.method hasPrefix:@"FaceDetector"]) {
            detector = [[FaceDetector alloc] initWithVision:[FIRVision vision] options:options];
        } else if ([call.method hasPrefix:@"ImageLabeler"]) {
            detector = [[ImageLabeler alloc] initWithVision:[FIRVision vision] options:options];
        } else if ([call.method hasPrefix:@"TextRecognizer"]) {
            detector = [[TextRecognizer alloc] initWithVision:[FIRVision vision] options:options];
        } else if ([call.method isEqualToString:@"VisionEdgeImageLabeler#processLocalImage"]) {
            detector = [[LocalVisionEdgeDetector alloc] initWithVision:[FIRVision vision]
                                                               options:options];
        } else if ([call.method isEqualToString:@"VisionEdgeImageLabeler#processRemoteImage"]) {
            detector = [[RemoteVisionEdgeDetector alloc] initWithVision:[FIRVision vision]
                                                                options:options];
        }
        [FLTFirebaseMlVisionPlugin addDetector:handle detector:detector];
    }
    [detectors[handle] handleDetection:image result:result];
}

- (FIRVisionImage *)dataToVisionImage:(NSDictionary *)imageData {
    NSString *imageType = imageData[@"type"];
    
    if ([@"file" isEqualToString:imageType]) {
        return [self filePathToVisionImage:imageData[@"path"]];
    } else if ([@"bytes" isEqualToString:imageType]) {
        return [self bytesToVisionImage:imageData];
    } else {
        NSString *errorReason = [NSString stringWithFormat:@"No image type for: %@", imageType];
        @throw [NSException exceptionWithName:NSInvalidArgumentException
                                       reason:errorReason
                                     userInfo:nil];
    }
}

- (FIRVisionImage *)filePathToVisionImage:(NSString *)filePath {
    UIImage *image = [UIImage imageWithContentsOfFile:filePath];
    
    if (image.imageOrientation != UIImageOrientationUp) {
        CGImageRef imgRef = image.CGImage;
        CGRect bounds = CGRectMake(0, 0, CGImageGetWidth(imgRef), CGImageGetHeight(imgRef));
        UIGraphicsBeginImageContext(bounds.size);
        CGContextDrawImage(UIGraphicsGetCurrentContext(), bounds, imgRef);
        UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        image = newImage;
    }
    
    return [[FIRVisionImage alloc] initWithImage:image];
}

- (FIRVisionImage *)bytesToVisionImage:(NSDictionary *)imageData {
    FlutterStandardTypedData *byteData = imageData[@"bytes"];
    NSData *imageBytes = byteData.data;
    
    NSDictionary *metadata = imageData[@"metadata"];
    NSArray *planeData = metadata[@"planeData"];
    size_t planeCount = planeData.count;
    
    NSNumber *width = metadata[@"width"];
    NSNumber *height = metadata[@"height"];
    
    NSNumber *rawFormat = metadata[@"rawFormat"];
    FourCharCode format = FOUR_CHAR_CODE(rawFormat.unsignedIntValue);
    
    CVPixelBufferRef pxBuffer = NULL;
    if (planeCount == 0) {
        @throw [NSException exceptionWithName:NSInvalidArgumentException
                                       reason:@"Can't create image buffer with 0 planes."
                                     userInfo:nil];
    } else if (planeCount == 1) {
        NSDictionary *plane = planeData[0];
        NSNumber *bytesPerRow = plane[@"bytesPerRow"];
        
        pxBuffer = [self bytesToPixelBuffer:width.unsignedLongValue
                                     height:height.unsignedLongValue
                                     format:format
                                baseAddress:(void *)imageBytes.bytes
                                bytesPerRow:bytesPerRow.unsignedLongValue];
    } else {
        pxBuffer = [self planarBytesToPixelBuffer:width.unsignedLongValue
                                           height:height.unsignedLongValue
                                           format:format
                                      baseAddress:(void *)imageBytes.bytes
                                         dataSize:imageBytes.length
                                       planeCount:planeCount
                                        planeData:planeData];
    }
    
    return [self pixelBufferToVisionImage:pxBuffer];
}

- (CVPixelBufferRef)bytesToPixelBuffer:(size_t)width
                                height:(size_t)height
                                format:(FourCharCode)format
                           baseAddress:(void *)baseAddress
                           bytesPerRow:(size_t)bytesPerRow {
    CVPixelBufferRef pxBuffer = NULL;
    CVPixelBufferCreateWithBytes(kCFAllocatorDefault, width, height, format, baseAddress, bytesPerRow,
                                 NULL, NULL, NULL, &pxBuffer);
    return pxBuffer;
}

- (CVPixelBufferRef)planarBytesToPixelBuffer:(size_t)width
                                      height:(size_t)height
                                      format:(FourCharCode)format
                                 baseAddress:(void *)baseAddress
                                    dataSize:(size_t)dataSize
                                  planeCount:(size_t)planeCount
                                   planeData:(NSArray *)planeData {
    size_t widths[planeCount];
    size_t heights[planeCount];
    size_t bytesPerRows[planeCount];
    
    void *baseAddresses[planeCount];
    baseAddresses[0] = baseAddress;
    
    size_t lastAddressIndex = 0;  // Used to get base address for each plane
    for (int i = 0; i < planeCount; i++) {
        NSDictionary *plane = planeData[i];
        
        NSNumber *width = plane[@"width"];
        NSNumber *height = plane[@"height"];
        NSNumber *bytesPerRow = plane[@"bytesPerRow"];
        
        widths[i] = width.unsignedLongValue;
        heights[i] = height.unsignedLongValue;
        bytesPerRows[i] = bytesPerRow.unsignedLongValue;
        
        if (i > 0) {
            size_t addressIndex = lastAddressIndex + heights[i - 1] * bytesPerRows[i - 1];
            baseAddresses[i] = baseAddress + addressIndex;
            lastAddressIndex = addressIndex;
        }
    }
    
    CVPixelBufferRef pxBuffer = NULL;
    CVPixelBufferCreateWithPlanarBytes(kCFAllocatorDefault, width, height, format, NULL, dataSize,
                                       planeCount, baseAddresses, widths, heights, bytesPerRows, NULL,
                                       NULL, NULL, &pxBuffer);
    
    return pxBuffer;
}

- (FIRVisionImage *)pixelBufferToVisionImage:(CVPixelBufferRef)pixelBufferRef {
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBufferRef];
    
    CIContext *temporaryContext = [CIContext contextWithOptions:nil];
    CGImageRef videoImage =
    [temporaryContext createCGImage:ciImage
                           fromRect:CGRectMake(0, 0, CVPixelBufferGetWidth(pixelBufferRef),
                                               CVPixelBufferGetHeight(pixelBufferRef))];
    
    UIImage *uiImage = [UIImage imageWithCGImage:videoImage];
    CVPixelBufferRelease(pixelBufferRef);
    CGImageRelease(videoImage);
    return [[FIRVisionImage alloc] initWithImage:uiImage];
}

+ (void)addDetector:(NSNumber *)handle detector:(id<Detector>)detector {
    if (detectors[handle]) {
        NSString *reason =
        [[NSString alloc] initWithFormat:@"Object for handle already exists: %d", handle.intValue];
        @throw [[NSException alloc] initWithName:NSInvalidArgumentException reason:reason userInfo:nil];
    }
    
    detectors[handle] = detector;
}

@end
