/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Main view controller for the AR experience.
*/

import ARKit
import SceneKit
import UIKit
import Vision
import VideoToolbox


struct ImageInformation {
    let name: String
    let description: String
    let image: UIImage
}

class ViewController: UIViewController, ARSCNViewDelegate, ARSKViewDelegate, ShutterButtonDelegate {
    
    @IBOutlet var sceneView: ARSCNView!
    
    var skView: ARSKView!
    
    @IBOutlet weak var blurView: UIVisualEffectView!
    
    /// The view controller that displays the status and "restart experience" UI.
    lazy var statusViewController: StatusViewController = {
        return children.lazy.compactMap({ $0 as? StatusViewController }).first!
    }()
    
    /// A serial queue for thread safety when modifying the SceneKit node graph.
    let updateQueue = DispatchQueue(label: Bundle.main.bundleIdentifier! +
        ".serialSceneKitQueue")
    
    /// Convenience accessor for the session owned by ARSCNView.
    var session: ARSession {
        return sceneView.session
    }
    
    var isImageDetected = false
    
    let images = ["coffee" : ImageInformation(name: "COFFEE", description: "Augmented Reality for INFORMATION HIDING", image: UIImage(named: "coffee")!)]
    var secretMessage = ""
    
    var shutterButtonRect: CGRect {
        let radius: CGFloat = ShutterButton.Constants.DefaultRadius
        let size: CGSize = CGSize(width: radius*2, height: radius*2)
        let origin: CGPoint = CGPoint(x: (view.bounds.width - size.width)/2.0, y: view.bounds.height - size.height - 24.0)
        return CGRect(origin: origin, size: size)
    }
    
    lazy var shutterButton: ShutterButton = {
       let button = ShutterButton(frame: self.shutterButtonRect)
        button.delegate = self
        return button
    }()
    
    lazy var shutter: Shutter = {
        return Shutter(frame: view.bounds)
    }()
    
    var isNewPicture = false
    var newPicture: ImageInformation?
    
    // MARK: - View Controller Life Cycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        sceneView.showsStatistics = true
        
        sceneView.delegate = self
        sceneView.session.delegate = self
        
        sceneView.addSubview(shutterButton)
        sceneView.addSubview(self.shutter)
        
//        skView = ARSKView(frame: self.sceneView.bounds)
//        skView.alpha = 0
//        skView.delegate = self

        // Hook up status view controller callback(s).
        statusViewController.restartExperienceHandler = { [unowned self] in
            self.restartExperience()
        }
        
        
//        timeLabel.text = ""
        
        setUpBoundingBoxes()
        setUpCoreImage()
        setUpVision()
        setUpCamera()
        
//        frameCapturingStartTime = CACurrentMediaTime()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Prevent the screen from being dimmed to avoid interuppting the AR experience.
        UIApplication.shared.isIdleTimerDisabled = true

        // Start the AR experience
        resetTracking()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        session.pause()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        print(#function)
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if let frameBuffer = self.sceneView.session.currentFrame?.capturedImage {
            
            let timestamp = CACurrentMediaTime()
            let deltaTime = timestamp - lastTimeStamp
            lastTimeStamp = timestamp
            
            if deltaTime > measureFPS() {
//                self.predictUsingVision(pixelBuffer: frameBuffer)
//                self.predict(pixelBuffer: frameBuffer)
                self.predict(image: sceneView.snapshot())
            }
        }
    }

    // MARK: - Session management (Image detection setup)
    
    /// Prevents restarting the session while a restart is in progress.
    var isRestartAvailable = true

    /// Creates a new AR configuration to run on the `session`.
    /// - Tag: ARReferenceImage-Loading
    func resetTracking() {
        
//        guard let referenceImages = ARReferenceImage.referenceImages(inGroupNamed: "AR Resources", bundle: nil) else {
//            fatalError("Missing expected asset catalog resources.")
//        }
        
        guard let referenceImages1 = ARReferenceImage.referenceImages(inGroupNamed: "Coffee", bundle: nil) else {
            fatalError("Missing expected asset catalog resources.")
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.detectionImages = referenceImages1
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        statusViewController.scheduleMessage("Look around to detect images", inSeconds: 7.5, messageType: .contentPlacement)
    }
    
    /// Create ARReference Images from somewhere other than the default folder
    func loadDynamicReferenceImage() {
        
        print("load reference image")
        
        // Get the image from the folder
        guard let imageFromBundle = UIImage(named: "Darko1"),
            // Convert it to a CIImage
            let imageToCIImage = CIImage(image: imageFromBundle),
            // Convert the CIImage to a CGImage
            let cgImage = convertCIImageToCGImage(inputImage: imageToCIImage) else {
                print("Unable to convert")
                return
        }
        
        // Create an ARReferenceImage (remembering physical width is in metres)
        let arImage = ARReferenceImage(cgImage, orientation: CGImagePropertyOrientation.up, physicalWidth: 0.1)
        
        // Name the image
        arImage.name = "Custom"
        
//        // Set the ARWorldTrackingConfiguration Detection Images
//        let configuration = ARWorldTrackingConfiguration()
//        configuration.detectionImages = [arImage]
//        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }
    
    /// Converts a CIImage to a CGImage
    func convertCIImageToCGImage(inputImage: CIImage) -> CGImage? {
        
        let context = CIContext(options: nil)
        if let cgImage = context.createCGImage(inputImage, from: inputImage.extent) {
            return cgImage
        }
        return nil
    }
    
    // Labels for classified objects by ARAnchor UUID
    private var anchorLabels = [UUID: String]()
    
    // Classification results
    private var identifierString = ""
    private var confidence: VNConfidence = 0.0
    
    @IBAction func placeTextAtLocation(sender: UITapGestureRecognizer) {
        
        if isImageDetected {
            print("Tap")
            
            let hiLocationInView = sender.location(in: sceneView)
            let hitTestResults = sceneView.hitTest(hiLocationInView, types: [.featurePoint, .estimatedHorizontalPlane])
            if let result = hitTestResults.first {
                
                // Add a new anchor at the tap location.
                let anchor = ARAnchor(transform: result.worldTransform)
                sceneView.session.add(anchor: anchor)
                
                // Track anchor ID to associate text with the anchor after ARKit creates a corresponding SCNNode
                anchorLabels[anchor.identifier] = identifierString
            }
        }
        
//        loadDynamicReferenceImage()
    }
    
    // Handle completion of the Vision request and choose results to display
    /// - Tag: ProcessClassifications
    func processClassifications(for request: VNRequest, error: Error?) {
        
        guard let results = request.results else {
            print("Unable to classify image.\n\(error!.localizedDescription)")
            return
        }
        
        // The `results` will always be `VNClassificationObservation`s, as specified by the CoreML model in this project.
        let classifications = results as! [VNClassificationObservation]
        
        // Show a label for the highest-confidence result (but only above a minimum confidence threshold).
        if let bestResult = classifications.first(where: { result in result.confidence > 0.5 }),
            let label = bestResult.identifier.split(separator: ",").first {
            identifierString = String(label)
            confidence = bestResult.confidence
        } else {
            identifierString = ""
            confidence = 0
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.displayClassifierResults()
        }
    }
    
    // Show the classification results in the UI.
    private func displayClassifierResults() {
        guard !self.identifierString.isEmpty else {
            return
        }
        let message = String(format: "Detected \(self.identifierString) with %.2f", self.confidence * 100) + "%confidence"
        statusViewController.showMessage(message)
    }

    // MARK: - ARSCNViewDelegate (Image detection results)
    /// - Tag: ARImageAnchor-Visualizing
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
//        guard let imageAnchor = anchor as? ARImageAnchor else { return }
//        let referenceImage = imageAnchor.referenceImage
        
        if let imageAnchor = anchor as? ARImageAnchor {
            
            let referenceImage = imageAnchor.referenceImage
            
            updateQueue.async {
                
                // Create a plane to visualize the initial position of the detected image.
                let plane = SCNPlane(width: referenceImage.physicalSize.width,
                                     height: referenceImage.physicalSize.height)
                let planeNode = SCNNode(geometry: plane)
                planeNode.opacity = 0.25
                
                /*
                 `SCNPlane` is vertically oriented in its local coordinate space, but
                 `ARImageAnchor` assumes the image is horizontal in its local space, so
                 rotate the plane to match.
                 */
                planeNode.eulerAngles.x = -.pi / 2
                
                /*
                 Image anchors are not tracked after initial detection, so create an
                 animation that limits the duration for which the plane visualization appears.
                 */
                planeNode.runAction(self.imageHighlightAction)
                
                // Add the plane visualization to the scene.
                node.addChildNode(planeNode)
                
                self.isImageDetected = true
            }
        }
        
        guard !(anchor is ARImageAnchor) else {
            return
        }
        
        if !isNewPicture {
            self.secretMessage = images["coffee"]!.description
        } else {
//            self.secretMessage = newPicture!.description
        }

        // Create 3D text
        let secretNode: SCNNode = createNewSecretParentNode("\(self.secretMessage)")
        node.addChildNode(secretNode)


//        DispatchQueue.main.async {
//            let imageName = referenceImage.name ?? ""
//            self.statusViewController.cancelAllScheduledMessages()
//            self.statusViewController.showMessage("Detected image “\(imageName)”")
//        }
    }
    
//    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
//
//        // If our target image has been detected, then get the corresponding anchor
//        guard let currentImageAnchor = anchor as? ARImageAnchor else { return }
//
//        let x = currentImageAnchor.transform
//        print(x.columns.3.x, x.columns.3.y, x.columns.3.z)
//
//        // Get the target's name
//        let name = currentImageAnchor.referenceImage.name!
//
//        // Get the target's width & height in meters
//        let width = currentImageAnchor.referenceImage.physicalSize.width
//        let height = currentImageAnchor.referenceImage.physicalSize.height
//
//        print("""
//            Image Name = \(name)
//            Image Width = \(width)
//            Image Height = \(height)
//            """)
//
//        // Create a plane geometry to cover the ARImageAnchor
//        let planeNode = SCNNode()
//        let planeGeometry = SCNPlane(width: width, height: height)
//        planeGeometry.firstMaterial?.diffuse.contents = UIColor.white
//        planeNode.opacity = 0.25
//        planeNode.geometry = planeGeometry
//
//        // Rotate the planeNode to horizontal
//        planeNode.eulerAngles.x = -.pi/2
//
//        planeNode.runAction(self.imageHighlightAction)
//
//        // The node is centered in the anchor (0,0,0)
//        node.addChildNode(planeNode)
//
//        // Create a SCNBox
////        let boxNode = SCNNode()
////        let boxGeometry = SCNBox(width: 0.1, height: 0.1, length: 0.1, chamferRadius: 0)
////
////        guard let labelText = anchorLabels[anchor.identifier] else {
////            fatalError("Missing expected associated label for anchor")
////        }
////        let label = TemplateLabelNode(text: labelText)
////        node.addChildNode(label)
//
////        let materialScene = SKScene(size: CGSize(width: width, height: height))
////        let labelNode = TemplateLabelNode(text: "🤓")
////        labelNode.position = CGPoint(x: width/2, y: height/2)
//////        labelNode.name = "LabelNode"
////        materialScene.addChild(labelNode)
////
//////        planeGeometry.firstMaterial?.diffuse.contents = materialScene
////        self.sceneView.overlaySKScene = materialScene
//
////        let materialScene = ARSKView(frame: CGRect(x: 0, y: 0, width: width, height: height))
////        let labelNode = TemplateLabelNode(text: "🤓")
////        labelNode.position = CGPoint(x: width/2, y: height/2)
////        //        labelNode.name = "LabelNode"
////
////        //        planeGeometry.firstMaterial?.diffuse.contents = materialScene
////        self.sceneView.overlaySKScene = materialScene
//
////        self.sceneView.addSubview(self.skView)
//
//        // Create 3D text
//        let secretNode: SCNNode = createNewSecretParentNode("This is a very serious secret message")
//        node.addChildNode(secretNode)
////        secretNode.position = word
//
//    }
    
//    func view(_ view: ARSKView, didAdd node: SKNode, for anchor: ARAnchor) {
//        let label = TemplateLabelNode(text: "🧠")
//        node.addChild(label)
//    }

    var imageHighlightAction: SCNAction {
        return .sequence([
            .wait(duration: 0.25),
            .fadeOpacity(to: 0.85, duration: 0.25),
            .fadeOpacity(to: 0.15, duration: 0.25),
            .fadeOpacity(to: 0.85, duration: 0.25),
            .fadeOut(duration: 0.5),
            .removeFromParentNode()
        ])
    }
    
    func createNewSecretParentNode(_ text: String) -> SCNNode {
        
        print("\(text)")
        
        // Warning: Creating 3D Text is susceptible to crashing.
        
        // Text Billboard constraint
        let billboardConstraint = SCNBillboardConstraint()
        billboardConstraint.freeAxes = SCNBillboardAxis.Y
        
        // Secret text
        let secret  = SCNText(string: text, extrusionDepth: 0.01)
        var font = UIFont(name: "Futura", size: 0.15)
        font = font?.withTraits(traits: .traitBold)
        secret.font = font
        secret.alignmentMode = CATextLayerAlignmentMode.center.rawValue
        secret.firstMaterial?.diffuse.contents = UIColor.white
        secret.firstMaterial?.specular.contents = UIColor.white
        secret.firstMaterial?.isDoubleSided = true
        secret.chamferRadius = 0.01
//        secret.flatness = 0.1
        
        // secret node
        let (minBound, maxBound) = secret.boundingBox
        let secretNode = SCNNode(geometry: secret)
        // Center node to center bottom point
        secretNode.pivot = SCNMatrix4MakeTranslation((maxBound.x - minBound.x)/2, minBound.y, 0.01/2)
        // Reduce default text size
        secretNode.scale = SCNVector3Make(0.2, 0.2, 0.2)
        
        // center point node
        let sphere = SCNSphere(radius: 0.005)
        sphere.firstMaterial?.diffuse.contents = UIColor.cyan
        let sphereNode = SCNNode(geometry: sphere)
        
        // secret parent node
        let secretNodeParent = SCNNode()
        secretNodeParent.addChildNode(secretNode)
//        secretNodeParent.addChildNode(sphereNode)
        secretNodeParent.constraints = [billboardConstraint]
        
        return secretNodeParent
    }
    
    
//    @IBOutlet weak var videoPreview: UIView!
//    @IBOutlet weak var timeLabel: UILabel!
//    @IBOutlet weak var debugImageView: UIImageView!
    
    let yolo = YOLO()
    
//    var videoCapture: VideoCapture!
    var request: VNCoreMLRequest!
    var startTimes: [CFTimeInterval] = []
    
    var boundingBoxes = [BoundingBox]()
    var boundingBox: [YOLO.Prediction]?
    var colors: [UIColor] = []
    
    let ciContext = CIContext()
    var resizedPixelBuffer: CVPixelBuffer?
    
    var framesDone = 0
    var frameCapturingStartTime = CACurrentMediaTime()
    let semaphore = DispatchSemaphore(value: 2)
    var lastTimeStamp = CACurrentMediaTime()
    var fps = 30
    static var deltaTime = 0
    
    var isPredicting = false
    var previousBuffer: CVPixelBuffer?
    
    
    // MARK: - Initialization
    
    
    func setUpBoundingBoxes() {
        for _ in 0..<YOLO.maxBoundingBoxes {
            boundingBoxes.append(BoundingBox())
        }
        
        // Make colors for the bounding boxes. There is one color for each class,
        // 20 classes in total.
        for r: CGFloat in [0.2, 0.4, 0.6, 0.8, 1.0] {
            for g: CGFloat in [0.1, 0.3, 0.5, 0.7] {
                for b: CGFloat in [0,2, 0.4, 0.6, 0.8] {
                    let color = UIColor(red: r, green: g, blue: b, alpha: 1)
                    colors.append(color)
                    //            colors.append(color)
                    //            colors.append(color)
                    //            colors.append(color)
                }
            }
        }
    }
    
    func setUpCoreImage() {
        let status = CVPixelBufferCreate(nil, YOLO.inputWidth, YOLO.inputHeight,
                                         kCVPixelFormatType_32BGRA, nil,
                                         &resizedPixelBuffer)
        if status != kCVReturnSuccess {
            print("Error: could not create resized pixel buffer", status)
        }
    }
    
    func setUpVision() {
        guard let visionModel = try? VNCoreMLModel(for: yolo.model.model) else {
            print("Error: could not create Vision model")
            return
        }
        
        request = VNCoreMLRequest(model: visionModel, completionHandler: visionRequestDidComplete)
        
        // NOTE: If you choose another crop/scale option, then you must also
        // change how the BoundingBox objects get scaled when they are drawn.
        // Currently they assume the full input image is used.
        request.imageCropAndScaleOption = .scaleFill
    }
    
    func setUpCamera() {
        for box in self.boundingBoxes {
            box.addToLayer(self.sceneView.layer)
        }
    }
    
    // MARK: - UI stuff
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
//        resizePreviewLayer()
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
    
//    func resizePreviewLayer() {
//        videoCapture.previewLayer?.frame = videoPreview.bounds
//    }
    
    // MARK: - Doing inference
    
    func predict(image: UIImage) {
        if let pixelBuffer = image.pixelBuffer(width: YOLO.inputWidth, height: YOLO.inputHeight) {
            predict(pixelBuffer: pixelBuffer)
        }
    }
    
    func predict(pixelBuffer: CVPixelBuffer) {
        // Measure how long it takes to predict a single video frame.
        let startTime = CACurrentMediaTime()
        
        // Resize the input with Core Image to 416x416.
        guard let resizedPixelBuffer = resizedPixelBuffer else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sx = CGFloat(YOLO.inputWidth) / CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let sy = CGFloat(YOLO.inputHeight) / CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let scaleTransform = CGAffineTransform(scaleX: sx, y: sy)
        let scaledImage = ciImage.transformed(by: scaleTransform)
        ciContext.render(scaledImage, to: resizedPixelBuffer)
        
        // This is an alternative way to resize the image (using vImage):
        //if let resizedPixelBuffer = resizePixelBuffer(pixelBuffer,
        //                                              width: YOLO.inputWidth,
        //                                              height: YOLO.inputHeight)
        
        // Resize the input to 416x416 and give it to our model.
        if let boundingBoxes = try? yolo.predict(image: resizedPixelBuffer) {
            let elapsed = CACurrentMediaTime() - startTime
            showOnMainThread(boundingBoxes, elapsed)
        }
    }
    
    func predictUsingVision(pixelBuffer: CVPixelBuffer) {
        print("Predicting using Vision")
        // Measure how long it takes to predict a single video frame. Note that
        // predict() can be called on the next frame while the previous one is
        // still being processed. Hence the need to queue up the start times.
        startTimes.append(CACurrentMediaTime())
        // Vision will automatically resize the input image.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)
        try? handler.perform([request])
    }
    
    func visionRequestDidComplete(request: VNRequest, error: Error?) {
        print("Vision request complete")
        if let observations = request.results as? [VNCoreMLFeatureValueObservation],
            let features = observations.first?.featureValue.multiArrayValue {
            
            let boundingBoxes = yolo.computeBoundingBoxes(features: features)
            let elapsed = CACurrentMediaTime() - startTimes.remove(at: 0)
            showOnMainThread(boundingBoxes, elapsed)
        }
    }
    
    func showOnMainThread(_ boundingBoxes: [YOLO.Prediction], _ elapsed: CFTimeInterval) {
        DispatchQueue.main.async {
            // For debugging, to make sure the resized CVPixelBuffer is correct.
            //var debugImage: CGImage?
            //VTCreateCGImageFromCVPixelBuffer(resizedPixelBuffer, nil, &debugImage)
            //self.debugImageView.image = UIImage(cgImage: debugImage!)
            
            self.show(predictions: boundingBoxes)
            
            let fps = self.measureFPS()
//            self.timeLabel.text = String(format: "Elapsed %.5f seconds - %.2f FPS", elapsed, fps)
            
            self.semaphore.signal()
        }
    }
    
    func measureFPS() -> Double {
        // Measure how many frames were actually delivered per second.
        framesDone += 1
        let frameCapturingElapsed = CACurrentMediaTime() - frameCapturingStartTime
        let currentFPSDelivered = Double(framesDone) / frameCapturingElapsed
        if frameCapturingElapsed > 1 {
            framesDone = 0
            frameCapturingStartTime = CACurrentMediaTime()
        }
//        return currentFPSDelivered
        return frameCapturingElapsed
    }
    
    func show(predictions: [YOLO.Prediction]) {
        
        print("First show predictions")
        for i in 0..<boundingBoxes.count {
            if i < predictions.count {
                let prediction = predictions[i]
                
                // The predicted bounding box is in the coordinate space of the input
                // image, which is a square image of 416x416 pixels. We want to show it
                // on the video preview, which is as wide as the screen and has a 4:3
                // aspect ratio. The video preview also may be letterboxed at the top
                // and bottom.
                let width = view.bounds.width
                let height = width * 16 / 9
                let scaleX = width / CGFloat(YOLO.inputWidth)
                let scaleY = height / CGFloat(YOLO.inputHeight)
                let top = (view.bounds.height - height) / 2
                
                // Translate and scale the rectangle to our own coordinate system.
                var rect = prediction.rect
                rect.origin.x *= scaleX
                rect.origin.y *= scaleY
                rect.origin.y += top
                rect.size.width *= scaleX
                rect.size.height *= scaleY
                
                // Show the bounding box.
                let label = String(format: "%@ %.1f", labels[prediction.classIndex], prediction.score * 100)
                let color = colors[prediction.classIndex]
                boundingBoxes[i].show(frame: rect, label: label, color: color)
            } else {
                boundingBoxes[i].hide()
            }
        }
    }

}


extension ViewController {
    
    private func takePicture() {
        
        isNewPicture = true
        
        var referenceImage: UIImage?
        
        shutter.flush()
//        DispatchQueue.global().async {
//            guard let imageBuffer = self.sceneView.snapshot() else {
//                return
//            }
        let image = self.sceneView.snapshot()
        //            UIImageWriteToSavedPhotosAlbum(UIImage(pixelBuffer: imageBuffer)!, nil, nil, nil)
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        
        let alertController = UIAlertController(title: "Secret Message", message: "Please enter the secret message", preferredStyle: UIAlertController.Style.alert)
        alertController.addTextField { secretTextField in
            secretTextField.placeholder = "SECRET MESSAGE"
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: UIAlertAction.Style.cancel, handler: nil)
        let okAction = UIAlertAction(title: "Confirm", style: .default) { _ in
            let secret = alertController.textFields![0]
            print("\(secret.text!)")
            self.secretMessage = secret.text ?? "DEFAULT MESSAGE"
        }
        
        alertController.addAction(cancelAction)
        alertController.addAction(okAction)
        
        self.present(alertController, animated: true, completion: nil)
        
        referenceImage = image
//       }
        
        let tmpImage = ImageInformation(name: "snapshot", description: self.secretMessage, image: image)
        
        newPicture = tmpImage
        
        let imageFromCamera = referenceImage!
        // Convert it to a CIImage
        let imageToCIImage = CIImage(image: imageFromCamera)
        // Convert the CIImage to a CGImage
        let cgImage = convertCIImageToCGImage(inputImage: imageToCIImage!)
        
        let arImage = ARReferenceImage(cgImage!, orientation: CGImagePropertyOrientation.up, physicalWidth: 0.1)
        
        // Name the image
        arImage.name = "Custom"

        let configuration = ARWorldTrackingConfiguration()
        configuration.detectionImages = [arImage]
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

    }
    
    func shutterButton(_ button: ShutterButton, didTapWith event: UIEvent) {
        print("shutter did tap")
        takePicture()
    }
    
    func shutterButtonDidDetectLongPress(_ button: ShutterButton) {
        //
        print("shutter did detect")
    }
    
    func shutterButtonDidFinishLongPress(_ button: ShutterButton) {
        print("shutter did finish")
        takePicture()
    }
    
}


/// - Tag: TemplateLabelNode
class TemplateLabelNode: SKReferenceNode {
    
    private let text: String
    
    init(text: String) {
        self.text = text
        // Force call to designated init(fileNamed: String?), not convenience init(fileNamed: String)
        super.init(fileNamed: Optional.some("LabelScene"))
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func didLoad(_ node: SKNode?) {
        // Apply text to both labels loaded from the template.
        guard let parent = node?.childNode(withName: "LabelNode") else {
            fatalError("misconfigured SpriteKit template file")
        }
        for case let label as SKLabelNode in parent.children {
            label.name = text
            label.text = text
        }
    }
}


extension UIFont {
    
    func withTraits(traits: UIFontDescriptor.SymbolicTraits...) -> UIFont {
        let descriptor = self.fontDescriptor.withSymbolicTraits(UIFontDescriptor.SymbolicTraits(traits))
        return UIFont(descriptor: descriptor!, size: 0)
    }
}


extension CGImage {
    
    public static func create(pixelBuffer: CVPixelBuffer) -> CGImage? {
        
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        return cgImage
    }
    
    public static func create(pixelBuffer: CVPixelBuffer, context: CIContext) -> CGImage? {
        
        let ciImage = CIImage(cvImageBuffer: pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        return context.createCGImage(ciImage, from: rect)
    }
}


extension UIImage {
    
    public convenience init?(pixelBuffer: CVPixelBuffer) {
        if let cgImage = CGImage.create(pixelBuffer: pixelBuffer) {
            self.init(cgImage: cgImage)
        } else {
            return nil
        }
    }
    
    public convenience init?(pixelBuffer: CVPixelBuffer, context: CIContext) {
        if let cgImage = CGImage.create(pixelBuffer: pixelBuffer, context: context) {
            self.init(cgImage: cgImage)
        } else {
            return nil
        }
    }
}
