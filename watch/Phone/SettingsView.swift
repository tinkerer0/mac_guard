import SwiftUI

/// 맥 지킴이 설정. 바꾸는 즉시 맥에 보내고, 맥이 설정 파일에 남겨 다시 켜도 유지된다.
struct SettingsView: View {
    let client: GuardClient
    @Binding var status: GuardStatusDTO?

    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?

    private static let alarmDelays: [Double] = [0, 3, 5, 10, 30]
    private static let armGraces: [Double] = [0, 3, 5]

    var body: some View {
        NavigationStack {
            Form {
                if let status, let alarmDelay = status.alarmDelaySeconds, let armGrace = status.armGraceSeconds {
                    Section {
                        Picker("Alarm after", selection: binding(alarmDelay, key: "alarmDelaySeconds")) {
                            ForEach(options(Self.alarmDelays, current: alarmDelay), id: \.self) { Text(label($0)).tag($0) }
                        }
                    } header: {
                        Text("Alarm")
                    } footer: {
                        Text("When someone touches the Mac, it locks right away. If it isn't unlocked within this time, your iPhone gets a notification. Your Apple Watch shows it too when the iPhone is locked.")
                    }
                    Section {
                        Toggle("Lock when touched", isOn: binding(status.lockOnTouch, key: "lockOnTouch"))
                        Picker("Start watching", selection: binding(armGrace, key: "armGraceSeconds")) {
                            ForEach(options(Self.armGraces, current: armGrace), id: \.self) { Text(label($0)).tag($0) }
                        }
                    } header: {
                        Text("Guard")
                    } footer: {
                        Text("How long after arming before touches count.")
                    }
                    Section {
                        Toggle("View screen without arming", isOn: binding(status.screenViewWhenDisarmed ?? false, key: "screenViewWhenDisarmed"))
                    } header: {
                        Text("Screen")
                    } footer: {
                        Text("When on, anyone with this app's access token can see your Mac screen while it's unlocked, even when you're at your desk.")
                    }
                } else if status == nil {
                    Text("Can't reach the Mac")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Update the Mac app to change settings here.")
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(saving)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// 화면에 보이는 값은 맥이 돌려준 상태를 따르고, 바꾸면 그 항목 하나만 맥에 보낸다.
    private func binding<Value>(_ current: Value, key: String) -> Binding<Value> {
        Binding(
            get: { current },
            set: { value in save([key: value]) }
        )
    }

    private func save(_ values: [String: Any]) {
        Task {
            saving = true
            defer { saving = false }
            do {
                status = try await client.updateSettings(values)
                error = nil
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Can't reach the Mac"
            }
        }
    }

    /// 설정 파일에 목록 밖의 값(예: 7초)이 있으면 그 값도 고를 수 있게 넣는다.
    private func options(_ values: [Double], current: Double) -> [Double] {
        values.contains(current) ? values : (values + [current]).sorted()
    }

    private func label(_ seconds: Double) -> String {
        seconds == 0 ? "Immediately" : "\(seconds.formatted(.number.precision(.fractionLength(0...1)))) seconds"
    }
}
