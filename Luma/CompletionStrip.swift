import SwiftUI

#if canImport(UIKit)
    @Observable
    final class CompletionCandidates {
        private(set) var words: [String] = []
        @ObservationIgnored private var accept: (String) -> Void = { _ in }

        func offer(_ words: [String], accept: @escaping (String) -> Void) {
            self.words = words
            self.accept = accept
        }

        func take(_ word: String) {
            accept(word)
        }
    }

    struct CompletionStrip: View {
        let candidates: CompletionCandidates

        var body: some View {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(candidates.words, id: \.self) { word in
                        Button(word) { candidates.take(word) }
                            .font(.system(.footnote, design: .monospaced))
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
            .background(.bar)
        }
    }
#endif
