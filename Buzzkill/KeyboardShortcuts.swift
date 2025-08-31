//
//  KeyboardShortcuts.swift
//  Buzzkill
//
//  Constants for keyboard shortcuts.
//

import KeyboardShortcuts

extension KeyboardShortcuts.Name {
  // Default: Option + Z.
  static let swatterActivation = Self(
    "swatterActivation",
    default: .init(.z, modifiers: [.option])
  )
}

// Helper for reverting to default when user clears the shortcut in the recorder.
enum KeyboardShortcutDefaults {
  static let swatterActivation: KeyboardShortcuts.Shortcut = .init(.z, modifiers: [.option])
}
