// Cross-platform UI extensions for iOS and macOS compatibility

import SwiftUI

extension View {
  @ViewBuilder
  func inlineNavigationBarTitle() -> some View {
    #if os(iOS)
      self.navigationBarTitleDisplayMode(.inline)
    #else
      self
    #endif
  }
}

extension ToolbarItemPlacement {
  static var trailingBar: ToolbarItemPlacement {
    #if os(iOS)
      return .navigationBarTrailing
    #else
      return .automatic
    #endif
  }
}
