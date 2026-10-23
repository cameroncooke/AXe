//
//  TextInputView.swift
//  AxePlayground
//
//  Created by Cameron on 23/05/2025.
//

import SwiftUI

// MARK: - Text Input View
struct TextInputView: View {
    @State private var inputText = ""
    @State private var isEditing = false
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Text Input Playground")
                    .font(.title2)
                    .fontWeight(.bold)
                    .accessibilityIdentifier("text-input-title")
                Text("Type directly to test text input")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("text-input-description")
            }
            .padding()
            .background(Color.white.opacity(0.9))
            .cornerRadius(12)
            .shadow(radius: 4)
            
            VStack(spacing: 16) {
                TextField("Type here...", text: $inputText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.title2)
                    .focused($isTextFieldFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    .accessibilityIdentifier("text-input-field")
                    .accessibilityValue(inputText.isEmpty ? "empty" : inputText)
                    .onChange(of: isTextFieldFocused) { _, focused in
                        isEditing = focused
                    }
                
                if isEditing {
                    Text("✏️ Typing active")
                        .font(.headline)
                        .foregroundColor(.green)
                        .padding()
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(8)
                        .accessibilityIdentifier("typing-active-indicator")
                }
                
                if !inputText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Input Analysis:")
                            .font(.headline)
                            .accessibilityIdentifier("input-analysis-title")
                        Text("Characters: \(inputText.count)")
                            .accessibilityIdentifier("character-count")
                            .accessibilityValue("\(inputText.count)")
                        Text("Words: \(inputText.split(separator: " ").count)")
                            .accessibilityIdentifier("word-count")
                            .accessibilityValue("\(inputText.split(separator: " ").count)")
                        Text("Lines: \(inputText.split(separator: "\n").count)")
                            .accessibilityIdentifier("line-count")
                            .accessibilityValue("\(inputText.split(separator: "\n").count)")
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()

            Spacer()
        }
        .padding()
        .navigationTitle("Text Input")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("text-input-screen")
        .onAppear {
            isTextFieldFocused = true
        }
    }
}
