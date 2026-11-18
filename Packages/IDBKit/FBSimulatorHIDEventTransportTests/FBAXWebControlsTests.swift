import CoreGraphics
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Hosted web controls")
struct FBAXWebControlsTests {
  private let screen = CGRect(x: 0, y: 0, width: 402, height: 874)

  @Test("The probe plan covers the screen in cells and starts at the centre")
  func probePlanCoversScreen() {
    let points = FBAXWebContentProbePlan.points(in: screen, spacing: 80)
    // 402 / 80 and 874 / 80 round down to 5 columns and 10 rows.
    #expect(points.count == 50)
    #expect(points.allSatisfy { screen.contains($0) })
    #expect(Set(points.map { "\($0.x),\($0.y)" }).count == 50)
    let distances = points.map { pow($0.x - screen.midX, 2) + pow($0.y - screen.midY, 2) }
    #expect(distances == distances.sorted())
    #expect(points == FBAXWebContentProbePlan.points(in: screen, spacing: 80))
  }

  @Test("A screen smaller than the spacing still gets one probe; bad input gets none")
  func probePlanEdges() {
    #expect(FBAXWebContentProbePlan.points(in: CGRect(x: 0, y: 0, width: 40, height: 60), spacing: 80) == [CGPoint(x: 20, y: 30)])
    #expect(FBAXWebContentProbePlan.points(in: .null, spacing: 80).isEmpty)
    #expect(FBAXWebContentProbePlan.points(in: .zero, spacing: 80).isEmpty)
    #expect(FBAXWebContentProbePlan.points(in: screen, spacing: 0).isEmpty)
    #expect(FBAXWebContentProbePlan.points(in: screen, spacing: .nan).isEmpty)
  }

  @Test("A control is tapped at the centre of its part on screen")
  func tapPoint() {
    #expect(FBAXWebControlPolicy.tapPoint(frame: CGRect(x: 16, y: 180, width: 300, height: 34), screen: screen)
      == CGPoint(x: 166, y: 197))
    #expect(FBAXWebControlPolicy.tapPoint(frame: CGRect(x: 0, y: 854, width: 100, height: 40), screen: screen)
      == CGPoint(x: 50, y: 864))
    #expect(FBAXWebControlPolicy.tapPoint(frame: CGRect(x: 0, y: 900, width: 100, height: 40), screen: screen) == nil)
    #expect(FBAXWebControlPolicy.tapPoint(frame: CGRect(x: 0, y: 873.5, width: 100, height: 40), screen: screen) == nil)
    #expect(FBAXWebControlPolicy.tapPoint(frame: .zero, screen: screen) == nil)
    #expect(FBAXWebControlPolicy.tapPoint(frame: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), screen: screen) == nil)
  }

  @Test("A container is followed only inside the process that was hit")
  func containerAcceptance() {
    #expect(FBAXWebControlPolicy.acceptsContainer(hitPID: 300, currentObjectID: 5, containerPID: 300, containerObjectID: 7))
    // Safari's own elements answer with an element of Safari.
    #expect(!FBAXWebControlPolicy.acceptsContainer(hitPID: 300, currentObjectID: 5, containerPID: 200, containerObjectID: 7))
    #expect(!FBAXWebControlPolicy.acceptsContainer(hitPID: 300, currentObjectID: 5, containerPID: 300, containerObjectID: 0))
    // An element that names itself would never end the climb.
    #expect(!FBAXWebControlPolicy.acceptsContainer(hitPID: 300, currentObjectID: 7, containerPID: 300, containerObjectID: 7))
    #expect(!FBAXWebControlPolicy.acceptsContainer(hitPID: 0, currentObjectID: 5, containerPID: 0, containerObjectID: 7))
  }

  @Test("A control is listed only when the element at its tap point is the control or its content")
  func hitShowsControl() {
    let control = FBSimulatorAXNativeIdentity(pid: 300, objectID: 10)
    let other = FBSimulatorAXNativeIdentity(pid: 300, objectID: 11)
    let frame = CGRect(x: 16, y: 210, width: 83, height: 23)
    let controls: Set<FBSimulatorAXNativeIdentity> = [control, other]
    func shows(_ hit: FBSimulatorAXNativeIdentity?, _ hitFrame: CGRect) -> Bool {
      FBAXWebControlPolicy.hitShowsControl(hit: hit, hitFrame: hitFrame, control: control,
        controlFrame: frame, controls: controls)
    }
    let text = CGRect(x: 18, y: 212, width: 70, height: 19)
    let itself = shows(control, .null)
    let ownText = shows(FBSimulatorAXNativeIdentity(pid: 300, objectID: 12), text)
    let otherControl = shows(other, text)
    let larger = shows(FBSimulatorAXNativeIdentity(pid: 300, objectID: 13), CGRect(x: 0, y: 0, width: 402, height: 500))
    let otherProcess = shows(FBSimulatorAXNativeIdentity(pid: 100, objectID: 10), frame)
    let nothing = shows(nil, frame)
    #expect(itself)
    // Its text, inside it.
    #expect(ownText)
    // Another control covering it.
    #expect(!otherControl)
    // A larger element over it (another web view, a sheet).
    #expect(!larger)
    // Another process: the app's own view, the keyboard, a second web view.
    #expect(!otherProcess)
    #expect(!nothing)
    // One of its two nearest containers that is not a control (a heading around a link).
    let heading = FBSimulatorAXNativeIdentity(pid: 300, objectID: 20)
    let group = FBSimulatorAXNativeIdentity(pid: 300, objectID: 21)
    let page = FBSimulatorAXNativeIdentity(pid: 300, objectID: 22)
    func showsWith(_ hit: FBSimulatorAXNativeIdentity) -> Bool {
      FBAXWebControlPolicy.hitShowsControl(hit: hit, hitFrame: CGRect(x: 0, y: 0, width: 402, height: 500),
        control: control, controlFrame: frame, controls: controls, parents: [heading, group, page])
    }
    #expect(showsWith(heading) && showsWith(group))
    #expect(!showsWith(page))
    #expect(!FBAXWebControlPolicy.hitShowsControl(hit: other, hitFrame: frame, control: control,
      controlFrame: frame, controls: controls, parents: [other]))
  }

  @Test("A link inside a heading is a link: the link trait without the static-text trait")
  func linkElement() {
    #expect(FBAXWebControlPolicy.isLinkElement(role: "AXHeading", traits: ["Link", "WebContent", "Header"]))
    #expect(!FBAXWebControlPolicy.isLinkElement(role: "AXHeading", traits: ["Link", "WebContent", "StaticText", "Header"]))
    #expect(!FBAXWebControlPolicy.isLinkElement(role: "AXHeading", traits: ["WebContent", "Header"]))
    #expect(!FBAXWebControlPolicy.isLinkElement(role: "AXStaticText", traits: ["Link"]))
    #expect(!FBAXWebControlPolicy.isLinkElement(role: "AXLink", traits: ["Link"]))
    #expect(!FBAXWebControlPolicy.isLinkElement(role: "AXGroup", traits: nil))
  }

  @Test("Subtrees wholly off screen are pruned; containers without a usable frame are walked")
  func pruning() {
    #expect(FBAXWebControlPolicy.mayContainVisibleControls(frame: CGRect(x: 0, y: -400, width: 402, height: 6000), screen: screen))
    #expect(!FBAXWebControlPolicy.mayContainVisibleControls(frame: CGRect(x: 0, y: 1200, width: 402, height: 300), screen: screen))
    #expect(!FBAXWebControlPolicy.mayContainVisibleControls(frame: CGRect(x: 2000, y: 140, width: 402, height: 340), screen: screen))
    #expect(FBAXWebControlPolicy.mayContainVisibleControls(frame: .zero, screen: screen))
    #expect(FBAXWebControlPolicy.mayContainVisibleControls(frame: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), screen: screen))
  }

  @Test("Containers are asked for children again after an empty answer; text leaves are not")
  func childrenRetry() {
    for role in ["AXGroup", "AXWebArea", "AXList", nil] as [String?] {
      #expect(FBAXWebControlPolicy.mayHaveChildren(role: role))
    }
    for role in ["AXStaticText", "AXImage", "AXHeading"] {
      #expect(!FBAXWebControlPolicy.mayHaveChildren(role: role))
    }
  }

  @Test("Input roles are controls; text, headings and groups are not")
  func controlRoles() {
    for role in ["AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton"] {
      #expect(FBAXWebControlPolicy.controlRoles.contains(role))
    }
    for role in ["AXStaticText", "AXHeading", "AXGroup", "AXImage", "AXWebArea"] {
      #expect(!FBAXWebControlPolicy.controlRoles.contains(role))
    }
  }

  @Test("An ARIA option lacks the static-text trait that page text carries")
  func selectableText() {
    // Measured on iOS 27.2: a role="option" list item, then a paragraph's text.
    #expect(FBAXWebControlPolicy.isSelectableText(traits: ["TextOperationsAvailable", "WebContent", "Scrollable"]))
    #expect(!FBAXWebControlPolicy.isSelectableText(traits: ["WebContent", "Scrollable", "StaticText", "TextOperationsAvailable"]))
    #expect(!FBAXWebControlPolicy.isSelectableText(traits: ["Scrollable"]))
    #expect(!FBAXWebControlPolicy.isSelectableText(traits: nil))
  }

  @Test("Keyboard keys and suggestions in a Safari sheet are not its controls")
  func keyboardKeys() {
    #expect(FBAXWebControlPolicy.isKeyboardKey(traits: ["KeyboardKey", "Scrollable", "PlaysSound"]))
    #expect(FBAXWebControlPolicy.isKeyboardKey(traits: ["DeleteKey"]))
    #expect(FBAXWebControlPolicy.isKeyboardKey(traits: ["AutoCorrectCandidate"]))
    #expect(!FBAXWebControlPolicy.isKeyboardKey(traits: ["Button"]))
    #expect(!FBAXWebControlPolicy.isKeyboardKey(traits: nil))
  }

  @Test("The accessory bar is looked for in rows above the keys, inside the screen")
  func accessoryBarPoints() {
    // The keys of a portrait iPhone keyboard; Done sat at y 493 to 531, the suggestions between.
    let points = FBAXWebControlPolicy.accessoryBarPoints(keyboard: CGRect(x: 0, y: 590, width: 402, height: 226), screen: screen)
    #expect(points.count == 18)
    #expect(points.allSatisfy { $0.y < 590 && $0.y > 470 && screen.contains($0) })
    #expect(points.contains { $0.y > 493 && $0.y < 531 && $0.x > 341 })
    #expect(FBAXWebControlPolicy.accessoryBarPoints(keyboard: CGRect(x: 0, y: 30, width: 402, height: 226), screen: screen).count == 3)
    #expect(FBAXWebControlPolicy.accessoryBarPoints(keyboard: .zero, screen: screen).isEmpty)
  }
}
