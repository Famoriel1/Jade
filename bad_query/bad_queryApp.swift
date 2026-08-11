//
//  bad_queryApp.swift
//  bad_query
//
//  Created by Taj C on 8/10/26.
//

import SwiftUI

@main
struct bad_queryApp: App {
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup {
            BQRootView()
                .environmentObject(state)
                .overlay {
                    if state.show_respring {
                        RespringView()
                            .brightness(-1.0)
                            .ignoresSafeArea()
                    }
                }
        }
    }
}
