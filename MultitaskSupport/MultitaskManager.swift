//
//  MultitaskManager.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

enum MultitaskMode : Int {
    case virtualWindow = 0
    case nativeWindow = 1
}

@objc class MultitaskManager : NSObject {
    static private var usingMultitaskContainers : [String] = []
    
    @objc class func isUsing(container: String) -> Bool {
        return IOSVMProcessRegistry.shared.isContainerBusy(container) || usingMultitaskContainers.contains { c in
            return c == container
        }
    }
    
    @objc class func isMultitasking() -> Bool {
        return IOSVMProcessRegistry.shared.hasActiveProcesses() || usingMultitaskContainers.count > 0
    }
}
