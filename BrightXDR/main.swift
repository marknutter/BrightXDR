//
//  main.swift
//  BrightXDR
//
//  Created by Dmitry Starkov on 31/03/2023.
//

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

_ = __NSApplicationLoad()
NSApp.run()
