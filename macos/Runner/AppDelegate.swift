import Cocoa
import FlutterMacOS
import ServiceManagement
import UserNotifications

@main
class AppDelegate: FlutterAppDelegate, UNUserNotificationCenterDelegate {
  var statusItem: NSStatusItem!
  var popover: NSPopover!
  var channel: FlutterMethodChannel!
  var flutterVC: FlutterViewController!

  override func applicationDidFinishLaunching(_ notification: Notification) {
    flutterVC = (mainFlutterWindow!.contentViewController as! FlutterViewController)

    // Method channel for Dart <-> Swift communication
    channel = FlutterMethodChannel(
      name: "com.jasoncamp.gnotify/menubar",
      binaryMessenger: flutterVC.engine.binaryMessenger
    )
    channel.setMethodCallHandler(handleMethodCall)

    // Popover hosting the Flutter UI.
    //
    // The Flutter view is wrapped in a plain container rather than being the
    // popover's content view directly. AppKit has a bug where mouseDown/mouseUp
    // are not forwarded up the responder chain for an NSPopover's content view
    // when "Reduce transparency" is on; Flutter relies on that forwarding and
    // only works around it below macOS 13.3.1, so on newer systems clicks are
    // silently dropped while keyboard input keeps working.
    // See https://github.com/flutter/flutter/issues/115015
    popover = NSPopover()
    popover.contentSize = NSSize(width: 420, height: 520)
    popover.behavior = .transient  // auto-dismiss on click outside
    popover.contentViewController = PopoverHostViewController(hosting: flutterVC)

    // Status bar icon; the length is variable so a count can sit beside it
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem.button {
      button.image = NSImage(named: "TrayIcon")
      button.image?.size = NSSize(width: 18, height: 18)
      button.imagePosition = .imageLeading
      button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
      button.target = self
      button.action = #selector(statusItemClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // Hide the XIB window; the popover is our only surface
    mainFlutterWindow!.orderOut(nil)

    // Deliver left-button events in the popover straight to Flutter. This is
    // the belt to the wrapper's braces above: it does not depend on AppKit's
    // popover responder chain at all. FlutterView's own mouseDown/Up/Dragged do
    // nothing but forward to the controller, so swallowing the event here
    // loses nothing and avoids a double dispatch when the chain does work.
    NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
      guard let self = self, self.popover.isShown,
            let window = event.window, window === self.flutterVC.view.window else {
        return event
      }
      switch event.type {
      case .leftMouseDown: self.flutterVC.mouseDown(with: event)
      case .leftMouseUp: self.flutterVC.mouseUp(with: event)
      case .leftMouseDragged: self.flutterVC.mouseDragged(with: event)
      default: return event
      }
      return nil
    }

    // Escape key closes the popover
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == 53, self?.popover.isShown == true {
        self?.popover.performClose(nil)
        return nil
      }
      return event
    }

    // Notifications
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
      if let error = error {
        NSLog("Notification authorization failed: \(error)")
      }
    }

    // One-time prompt to enable launch at login
    promptLaunchAtLoginIfNeeded()
  }

  private func promptLaunchAtLoginIfNeeded() {
    guard #available(macOS 13.0, *) else { return }

    let key = "hasPromptedLaunchAtLogin"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)

    let alert = NSAlert()
    alert.messageText = "Launch gnotify at Login?"
    alert.informativeText = "Would you like gnotify to start automatically when you log in? You can change this later from the menubar icon."
    alert.addButton(withTitle: "Yes")
    alert.addButton(withTitle: "No")
    alert.alertStyle = .informational

    if alert.runModal() == .alertFirstButtonReturn {
      try? SMAppService.mainApp.register()
    }
  }

  @objc func statusItemClicked(_ sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }
    if event.type == .rightMouseUp {
      showContextMenu(sender)
    } else {
      togglePopover(sender)
    }
  }

  func togglePopover(_ sender: NSStatusBarButton) {
    if popover.isShown {
      popover.performClose(sender)
    } else {
      showPopover(sender)
    }
  }

  func showPopover(_ sender: NSStatusBarButton) {
    // An LSUIElement app is not the active app when its status item is
    // clicked. Key events only reach the active app's key window, so without
    // activation the popover draws but every text field looks read-only.
    // On macOS 14+ activation is cooperative and may land a moment later, so
    // focus is also (re)applied from didBecomeActive below.
    activateApp()
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    focusPopover()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      self?.focusPopover()
    }
    channel.invokeMethod("popoverOpened", arguments: nil)
  }

  private func activateApp() {
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  /// Make the popover window key and hand first responder to the Flutter view.
  private func focusPopover() {
    guard popover.isShown,
          let host = popover.contentViewController as? PopoverHostViewController,
          let view = host.children.first?.view,
          let window = view.window else { return }
    if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
    if window.firstResponder !== view { window.makeFirstResponder(view) }
  }

  // Activation can be granted after the popover is already up; refocus then.
  override func applicationDidBecomeActive(_ notification: Notification) {
    super.applicationDidBecomeActive(notification)
    focusPopover()
  }

  func showContextMenu(_ sender: NSStatusBarButton) {
    let menu = NSMenu()

    menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refreshClicked), keyEquivalent: "r"))
    menu.addItem(NSMenuItem(title: "Settings…", action: #selector(settingsClicked), keyEquivalent: ","))
    menu.addItem(.separator())

    if #available(macOS 13.0, *) {
      let launchItem = NSMenuItem(
        title: "Launch at Login",
        action: #selector(toggleLaunchAtLogin(_:)),
        keyEquivalent: ""
      )
      launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
      menu.addItem(launchItem)
      menu.addItem(.separator())
    }

    menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil  // clear so left-click works next time
  }

  @available(macOS 13.0, *)
  @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
    do {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
    } catch {
      NSLog("Failed to toggle launch at login: \(error)")
    }
  }

  @objc func refreshClicked() {
    channel.invokeMethod("refresh", arguments: nil)
  }

  @objc func settingsClicked() {
    channel.invokeMethod("openSettings", arguments: nil)
    if let button = statusItem.button, !popover.isShown {
      showPopover(button)
    }
  }

  func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "updateTooltip":
      statusItem.button?.toolTip = call.arguments as? String
      result(nil)
    case "updateBadge":
      let count = call.arguments as? Int ?? 0
      statusItem.button?.title = count > 0 ? " \(count)" : ""
      result(nil)
    case "notify":
      guard let args = call.arguments as? [String: Any],
            let id = args["id"] as? String,
            let title = args["title"] as? String else {
        result(FlutterError(code: "bad_args", message: "notify needs id and title", details: nil))
        return
      }
      sendNotification(
        id: id,
        title: title,
        body: args["body"] as? String ?? "",
        url: args["url"] as? String
      )
      result(nil)
    case "openUrl":
      if let s = call.arguments as? String, let url = URL(string: s) {
        NSWorkspace.shared.open(url)
      }
      result(nil)
    case "closePopover":
      popover.performClose(nil)
      result(nil)
    case "quit":
      result(nil)
      NSApp.terminate(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Notifications

  func sendNotification(id: String, title: String, body: String, url: String?) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    if let url = url { content.userInfo = ["url": url] }

    let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { error in
      if let error = error { NSLog("Failed to deliver notification: \(error)") }
    }
  }

  // Show banners even while the popover is frontmost
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(macOS 11.0, *) {
      completionHandler([.banner, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  // Clicking a notification opens the PR in the browser
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let s = response.notification.request.content.userInfo["url"] as? String,
       let url = URL(string: s) {
      NSWorkspace.shared.open(url)
    }
    completionHandler()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

/// Plain container that hosts the Flutter view controller as a child, so the
/// FlutterView is a subview of the popover's content view rather than the
/// content view itself.
class PopoverHostViewController: NSViewController {
  private let hosted: NSViewController

  init(hosting: NSViewController) {
    self.hosted = hosting
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func loadView() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 520))
    container.wantsLayer = true
    addChild(hosted)
    hosted.view.frame = container.bounds
    hosted.view.autoresizingMask = [.width, .height]
    container.addSubview(hosted.view)
    view = container
  }
}
