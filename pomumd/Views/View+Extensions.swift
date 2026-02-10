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

extension View {
  @ViewBuilder
  func navigationBarItems<Leading: View, Trailing: View>(
    leading: Leading,
    trailing: Trailing
  ) -> some View {
    #if os(iOS)
      self.navigationBarItems(leading: leading, trailing: trailing)
    #else
      self.toolbar {
        ToolbarItem(placement: .cancellationAction) {
          leading
        }
        ToolbarItem(placement: .confirmationAction) {
          trailing
        }
      }
    #endif
  }
}
