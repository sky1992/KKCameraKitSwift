import AVFoundation
import UIKit

final class CameraPreviewView: UIView {
    var cameraPosition: AVCaptureDevice.Position = .front {
        didSet {
            guard oldValue != cameraPosition else { return }
            reconfigureSessionForCameraPosition()
        }
    }

    var photoCaptureCompletion: ((UIImage?) -> Void)?

    let cameraWorkQueue = DispatchQueue(label: "camera.work.queue", qos: .background)
    private let captureSession = AVCaptureSession()
    private var cameraDeviceInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isSessionConfigured = false
    fileprivate var photoDelegate: PhotoCaptureDelegate?
    private let maskOverlayView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        setupMaskOverlayView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
        setupMaskOverlayView()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
        maskOverlayView.frame = bounds
    }

    func updateMaskOverlayImage(_ image: UIImage?) {
        maskOverlayView.image = image
    }

    private func setupMaskOverlayView() {
        maskOverlayView.contentMode = .scaleToFill
        maskOverlayView.clipsToBounds = false
        addSubview(maskOverlayView)
    }

    func startCameraSession() {
        cameraWorkQueue.async { [weak self] in
            guard let self else { return }
            self.configureSessionIfNeeded()
            guard !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
    }

    func stopCameraSession() {
        cameraWorkQueue.async { [weak self] in
            guard let self else { return }
            guard self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
        }
    }

    func takePhoto() {
        cameraWorkQueue.async { [weak self] in
            guard let self else { return }
            self.configureSessionIfNeeded()
            guard self.captureSession.isRunning else { return }
            guard let videoConnection = self.photoOutput.connection(with: .video),
                  videoConnection.isEnabled
            else { return }

            let photoSettings = AVCapturePhotoSettings()
            let delegate = PhotoCaptureDelegate(host: self)
            self.photoDelegate = delegate
            self.photoOutput.capturePhoto(with: photoSettings, delegate: delegate)
        }
    }

    private func configureSessionIfNeeded() {
        guard !isSessionConfigured else { return }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720

        for case let input as AVCaptureDeviceInput in captureSession.inputs {
            captureSession.removeInput(input)
        }
        if captureSession.outputs.contains(photoOutput) {
            captureSession.removeOutput(photoOutput)
        }

        let targetCamera = getWideCameraDevice(for: cameraPosition)
        guard let device = targetCamera,
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input)
        else {
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(input)
        cameraDeviceInput = input

        guard captureSession.canAddOutput(photoOutput) else {
            captureSession.removeInput(input)
            cameraDeviceInput = nil
            captureSession.commitConfiguration()
            return
        }
        captureSession.addOutput(photoOutput)

        captureSession.commitConfiguration()
        isSessionConfigured = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let layer = self.previewLayer {
                layer.frame = self.bounds
            } else {
                let layer = AVCaptureVideoPreviewLayer(session: self.captureSession)
                layer.videoGravity = .resizeAspectFill
                layer.frame = self.bounds
                self.layer.insertSublayer(layer, at: 0)
                self.previewLayer = layer
            }
        }
    }

    private func reconfigureSessionForCameraPosition() {
        cameraWorkQueue.async { [weak self] in
            guard let self, self.isSessionConfigured else { return }
            let isSessionRunning = self.captureSession.isRunning
            if isSessionRunning {
                self.captureSession.stopRunning()
            }

            self.captureSession.beginConfiguration()
            for case let input as AVCaptureDeviceInput in self.captureSession.inputs {
                self.captureSession.removeInput(input)
            }
            let targetCamera = self.getWideCameraDevice(for: self.cameraPosition)
            if let device = targetCamera,
               let input = try? AVCaptureDeviceInput(device: device),
               self.captureSession.canAddInput(input)
            {
                self.captureSession.addInput(input)
                self.cameraDeviceInput = input
            }
            self.captureSession.commitConfiguration()

            if isSessionRunning {
                self.captureSession.startRunning()
            }
        }
    }

    private func getWideCameraDevice(for preferredPosition: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        
        var frontUltraCamera: AVCaptureDevice?
        var frontWideCamera: AVCaptureDevice?
        var backUltraCamera: AVCaptureDevice?
        var backWideCamera: AVCaptureDevice?
        
        for device in discoverySession.devices {
            switch device.position {
            case .front:
                if device.deviceType == .builtInUltraWideCamera {
                    frontUltraCamera = device
                } else {
                    frontWideCamera = device
                }
            case .back:
                if device.deviceType == .builtInUltraWideCamera {
                    backUltraCamera = device
                } else {
                    backWideCamera = device
                }
            default: break
            }
        }
        
        switch preferredPosition {
        case .front:
            return frontUltraCamera ?? frontWideCamera
        case .back:
            return backUltraCamera ?? backWideCamera
        default:
            return backUltraCamera ?? backWideCamera
        }
    }


    fileprivate func processCapturedImage(
        rawImage: UIImage,
        devicePosition: AVCaptureDevice.Position,
        completion: @escaping (UIImage?) -> Void
    ) {
        let processedImage: UIImage?
        switch devicePosition {
        case .front:
            processedImage = Self.mirrorImageHorizontally(rawImage)
        case .back:
            processedImage = Self.rotateImageCounterClockwise90(rawImage)
        default:
            processedImage = rawImage
        }
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        DispatchQueue.main.async {
            completion(processedImage)
        }
    }

    fileprivate func getCurrentCameraPosition() -> AVCaptureDevice.Position {
        cameraDeviceInput?.device.position ?? cameraPosition
    }

    private static func mirrorImageHorizontally(_ image: UIImage) -> UIImage? {
        let size = image.size
        let scale = image.scale
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        defer { UIGraphicsEndImageContext() }
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        ctx.translateBy(x: size.width, y: 0)
        ctx.scaleBy(x: -1, y: 1)
        image.draw(in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext()
    }

    private static func rotateImageCounterClockwise90(_ image: UIImage) -> UIImage? {
        let size = image.size
        let scale = image.scale
        let newSize = CGSize(width: size.height, height: size.width)
        UIGraphicsBeginImageContextWithOptions(newSize, false, scale)
        defer { UIGraphicsEndImageContext() }
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        ctx.translateBy(x: 0, y: newSize.height)
        ctx.rotate(by: -.pi / 2)
        image.draw(in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}


private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private weak var host: CameraPreviewView?

    init(host: CameraPreviewView) {
        self.host = host
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard let host else { return }
        defer { host.photoDelegate = nil }

        if error != nil {
            DispatchQueue.main.async {
                host.photoCaptureCompletion?(nil)
            }
            return
        }
        guard let data = photo.fileDataRepresentation(),
              let rawImage = UIImage(data: data)
        else {
            DispatchQueue.main.async {
                host.photoCaptureCompletion?(nil)
            }
            return
        }

        let position = host.getCurrentCameraPosition()
        host.cameraWorkQueue.async {
            host.processCapturedImage(rawImage: rawImage, devicePosition: position) { processed in
                host.photoCaptureCompletion?(processed)
            }
        }
    }
}
