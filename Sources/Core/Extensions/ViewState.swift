import SwiftUI

// Use the State property wrapper directly because the Command Line Tools
// can expose the State macro without shipping its SwiftUIMacros plugin.
typealias ViewState<Value> = SwiftUI.State<Value>
