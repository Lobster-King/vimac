//
//  AppDelegate.swift
//  ViMac-Swift
//
//  Created by Dexter Leng on 6/9/19.
//  Copyright © 2019 Dexter Leng. All rights reserved.
//

import Cocoa
import AXSwift
import RxSwift
import MASShortcut
import os
import Sparkle
import LaunchAtLogin
import Preferences

@NSApplicationMain
    class AppDelegate: NSObject, NSApplicationDelegate {
    var welcomeWindowController: NSWindowController?
    var permissionPollingTimer: Timer?
    
    let applicationObservable: Observable<Application?>
    let applicationNotificationObservable: Observable<AccessibilityObservables.AppNotificationAppPair>
    let windowObservable: Observable<UIElement?>
    let windowSubject: BehaviorSubject<UIElement?>
    let hintModeShortcutObservable: Observable<Void>
    let scrollModeShortcutObservable: Observable<Void>
    
    var compositeDisposable: CompositeDisposable
    var scrollModeDisposable: CompositeDisposable? = CompositeDisposable()
    
    let modeCoordinator: ModeCoordinator
    let overlayWindowController: OverlayWindowController

    static let windowEvents: [AXNotification] = [.windowMiniaturized, .windowMoved, .windowResized]
    
    override init() {
        InputSourceManager.initialize()
        let storyboard = NSStoryboard.init(name: "Main", bundle: nil)
        overlayWindowController = storyboard.instantiateController(withIdentifier: "overlayWindowControllerID") as! OverlayWindowController
        modeCoordinator = ModeCoordinator(windowController: overlayWindowController)
        
        Utils.registerDefaults()
        
        applicationObservable = AccessibilityObservables.createApplicationObservable().share()
        applicationNotificationObservable = AccessibilityObservables.createApplicationNotificationObservable(applicationObservable: applicationObservable, notifications: AppDelegate.windowEvents + [AXNotification.focusedWindowChanged]).share()
        
        let initialWindowFromApplicationObservable: Observable<UIElement?> = applicationObservable
            .map { appOptional in
                guard let app = appOptional else {
                    return nil
                }
                let windowOptional: UIElement? = try? app.attribute(Attribute.focusedWindow)
                return windowOptional
            }
        
        let windowFromApplicationNotificationObservable: Observable<UIElement?> = applicationNotificationObservable
            .flatMapLatest { pair in
                return Observable.create { observer in
                    guard let notification = pair.notification,
                        let app = pair.app else {
                        observer.onNext(nil)
                        return Disposables.create()
                    }
                    
                    if notification != .focusedWindowChanged {
                        return Disposables.create()
                    }
                    
                    let windowOptional: UIElement? = try? app.attribute(Attribute.focusedWindow)
                    observer.onNext(windowOptional)
                    return Disposables.create()
                }
            }
        
        windowObservable = Observable.merge([windowFromApplicationNotificationObservable, initialWindowFromApplicationObservable])
        windowSubject = BehaviorSubject(value: nil)

        hintModeShortcutObservable = Observable.create { observer in
            let tempView = MASShortcutView.init()
            tempView.associatedUserDefaultsKey = Utils.hintModeShortcutKey
            if tempView.shortcutValue == nil {
                tempView.shortcutValue = Utils.defaultHintShortcut
            }
            
            MASShortcutBinder.shared()
                .bindShortcut(withDefaultsKey: Utils.hintModeShortcutKey, toAction: {
                    observer.onNext(Void())
                })
            return Disposables.create()
        }
        
        scrollModeShortcutObservable = Observable.create { observer in
            let tempView = MASShortcutView.init()
            tempView.associatedUserDefaultsKey = Utils.scrollModeShortcutKey
            if tempView.shortcutValue == nil {
                tempView.shortcutValue = Utils.defaultScrollShortcut
            }
            
            MASShortcutBinder.shared()
                .bindShortcut(withDefaultsKey: Utils.scrollModeShortcutKey, toAction: {
                    observer.onNext(Void())
                })
            return Disposables.create()
        }
        
        LaunchAtLogin.isEnabled = UserDefaults.standard.bool(forKey: Utils.shouldLaunchOnStartupKey)
        
        self.compositeDisposable = CompositeDisposable()
        
        super.init()
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if self.isAccessibilityPermissionsGranted() {
            self.checkForUpdatesInBackground()
            self.setupWindowEventAndShortcutObservables()
            return
        }
        
        showWelcomeWindowController()
    }
    
    func showWelcomeWindowController() {
        let storyboard = NSStoryboard.init(name: "Main", bundle: nil)
        welcomeWindowController = storyboard.instantiateController(withIdentifier: "WelcomeWindowController") as! NSWindowController
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindowController?.showWindow(nil)
        welcomeWindowController?.window?.makeKeyAndOrderFront(nil)
        permissionPollingTimer = Timer.scheduledTimer(
            timeInterval: 2.0,
            target: self,
            selector: #selector(closeWelcomeWindowControllerWhenPermissionGranted),
            userInfo: nil,
            repeats: true
        )
    }
    
    @objc func closeWelcomeWindowControllerWhenPermissionGranted() {
        if self.isAccessibilityPermissionsGranted() {
            permissionPollingTimer?.invalidate()
            permissionPollingTimer = nil
            welcomeWindowController?.close()
            welcomeWindowController = nil
            
            self.checkForUpdatesInBackground()
            self.setupWindowEventAndShortcutObservables()
        }
    }
    
    func setupWindowEventAndShortcutObservables() {
        self.compositeDisposable.insert(applicationObservable
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: { appOptional in
                os_log("Current frontmost application: %@", log: Log.accessibility, String(describing: appOptional))
                if let app = appOptional {
                    Utils.setAccessibilityAttributes(app: app)
                }
            })
        )

        self.compositeDisposable.insert(applicationNotificationObservable
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: { pair in
                if let notification = pair.notification,
                    let app = pair.app {
                    
                    if notification == .focusedWindowChanged {
                        return
                    }

                    self.modeCoordinator.exitMode()
                }
            })
        )
        
        self.compositeDisposable.insert(windowObservable
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: { windowOptional in
                self.modeCoordinator.exitMode()
                os_log("Current window: %@", log: Log.accessibility, String(describing: windowOptional))
                self.windowSubject.onNext(windowOptional)
            })
        )

        let windowNoNilObservable = windowObservable.compactMap { $0 }
        
        self.compositeDisposable.insert(hintModeShortcutObservable
            .withLatestFrom(windowNoNilObservable, resultSelector: { _, window in
                return window
            })
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: { [weak self] window in
                if self?.modeCoordinator.windowController.window?.contentViewController?.className == HintModeViewController.className() {
                    self?.modeCoordinator.exitMode()
                } else {
                    self?.modeCoordinator.setHintMode()
                }
            })
        )
        
        self.compositeDisposable.insert(scrollModeShortcutObservable
            .withLatestFrom(windowNoNilObservable, resultSelector: { _, window in
                return window
            })
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: { [weak self] window in
                if self?.modeCoordinator.windowController.window?.contentViewController?.className == ScrollModeViewController.className() {
                    self?.modeCoordinator.exitMode()
                } else {
                    self?.modeCoordinator.setScrollMode()
                }
            })
        )
    }
    
    func checkForUpdatesInBackground() {
        SUUpdater.shared()?.delegate = self
        SUUpdater.shared()?.sendsSystemProfile = true
        SUUpdater.shared()?.checkForUpdatesInBackground()
    }
    
    func isAccessibilityPermissionsGranted() -> Bool {
        return UIElement.isProcessTrusted(withPrompt: false)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        self.compositeDisposable.dispose()
    }
}

extension AppDelegate : SUUpdaterDelegate {
}
