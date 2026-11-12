//
//  LCHelpView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2025/1/4.
//

import SwiftUI

struct LCHelpView : View {
    @Binding var isPresent : Bool
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading) {
                    Text("lc.helpView.text1".loc)
                    Text("")
                    Text("lc.helpView.text2".loc)
                }
                .padding()
            }
            .navigationTitle("lc.helpView.title".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem {
                    Button("lc.common.done".loc) {
                        isPresent = false
                    }
                }
            }
        }
    }
}
