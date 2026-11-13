import SwiftUI
import BCStore

/// Single source of truth for the memory-budget preference.
enum MemorySetting {
    static let key = "maxLogMemoryGB"
    static let defaultGB = 4.0
    static let range = 0.5...64.0
    static let step = 0.5

    static func bytes(forGB gb: Double) -> Int {
        Int(min(max(gb, range.lowerBound), range.upperBound) * 1_073_741_824)
    }
}

struct SettingsView: View {
    let budget: MemoryBudget
    @AppStorage(MemorySetting.key) private var maxMemoryGB = MemorySetting.defaultGB

    var body: some View {
        Form {
            Stepper(value: $maxMemoryGB, in: MemorySetting.range, step: MemorySetting.step) {
                LabeledContent("Maximum memory for logs") {
                    Text("\(maxMemoryGB.formatted(.number.precision(.fractionLength(1)))) GB")
                }
            }
            Text("When the limit is reached, the oldest log messages are discarded. Lowering the limit takes effect immediately.")
                .font(.callout)
                .foregroundStyle(.secondary)
            #if DEBUG
            if AppEnvironment.debugLimitOverrideBytes != nil {
                Text("Overridden by BETTERCONSOLE_MEMORY_LIMIT_MB for this debug run.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            #endif
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: maxMemoryGB) { _, gb in
            #if DEBUG
            if AppEnvironment.debugLimitOverrideBytes != nil { return }
            #endif
            budget.limitBytes = MemorySetting.bytes(forGB: gb)
        }
    }
}
