//
//  ClickOutsideEditableTextFieldObserver.swift
//  PureQ
//

import AppKit
import SwiftUI

struct ClickOutsideEditableTextFieldObserver: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.installIfNeeded()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.installIfNeeded()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        private var monitor: Any?

        func installIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                guard let window = event.window,
                      let contentView = window.contentView else {
                    return event
                }

                let point = contentView.convert(event.locationInWindow, from: nil)
                let hitView = contentView.hitTest(point)
                if hitView?.isInsideEditableTextInput != true {
                    window.endEditing(for: nil)
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            remove()
        }
    }
}

private extension NSView {
    var isInsideEditableTextInput: Bool {
        var view: NSView? = self
        while let currentView = view {
            if let textField = currentView as? NSTextField, textField.isEditable {
                return true
            }
            if currentView is NSTextView {
                return true
            }
            view = currentView.superview
        }
        return false
    }
}

