import Cocoa
import FlutterMacOS
import ServiceManagement
import UserNotifications

@main
class AppDelegate: FlutterAppDelegate, UNUserNotificationCenterDelegate {
  var statusItem: NSStatusItem!
  var popover: NSPopover!
  var channel: FlutterMethodChannel!

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let flutterVC = mainFlutterWindow!.contentViewController as! FlutterViewController

    // Method channel for Dart <-> Swift communication
    channel = FlutterMethodChannel(
      name: "com.jasoncamp.gnotify/menubar",
      binaryMessenger: flutterVC.engine.binaryMessenger
    )
    channel.setMethodCallHandler(handleMethodCall)

    // Popover hosting the Flutter UI
    popover = NSPopover()
    popover.contentSize = NSSize(width: 420, height: 520)
    popover.behavior = .transient  // auto-dismiss on click outside
    popover.contentViewController = flutterVC

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
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
    channel.invokeMethod("popoverOpened", arguments: nil)
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
