import SwiftUI

struct ProxySettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var detectedInfo: DetectedSystemProxyInfo = ProxyManager.detectSystemProxy()
    @State private var portText: String = ""
    @State private var isTesting = false
    @State private var testResult: ProxyTestResult?
    @State private var importedToast = false

    var body: some View {
        CompatNavigationStack {
            Form {
                systemStatusSection
                modeSection
                if settings.proxySettings.mode == .manual {
                    manualConfigSection
                }
                connectivityTestSection
            }
            .navigationTitle("代理设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                portText = settings.proxySettings.port > 0 ? String(settings.proxySettings.port) : ""
                detectedInfo = ProxyManager.detectSystemProxy()
            }
            .alert("已填入手动代理", isPresented: $importedToast) {
                Button("好", role: .cancel) {}
            } message: {
                Text("已将当前检测到的代理地址自动填入。")
            }
        }
    }

    private var systemStatusSection: some View {
        Section("当前网络状态") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(detectedInfo.hasAnyProxyOrVPN ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 9, height: 9)
                    Text(detectedInfo.summaryTitle)
                        .font(.subheadline.weight(.semibold))
                }

                ForEach(detectedInfo.detailLines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            Button {
                detectedInfo = ProxyManager.detectSystemProxy()
                testResult = nil
            } label: {
                Label("刷新检测", systemImage: "arrow.clockwise")
            }

            if let host = detectedInfo.primaryProxyHost,
               let port = detectedInfo.primaryProxyPort {
                Button {
                    settings.proxySettings.mode = .manual
                    settings.proxySettings.manualType = detectedInfo.primaryProxyType
                    settings.proxySettings.host = host
                    settings.proxySettings.port = port
                    portText = String(port)
                    importedToast = true
                } label: {
                    Label("使用 \(host):\(port) 作为手动代理", systemImage: "square.and.arrow.down")
                }
            }
        }
    }

    private var modeSection: some View {
        Section {
            ForEach(ProxyMode.allCases) { mode in
                Button {
                    settings.proxySettings.mode = mode
                    testResult = nil
                } label: {
                    HStack {
                        Text(mode.displayTitle)
                            .foregroundStyle(.primary)
                            .font(.subheadline.weight(settings.proxySettings.mode == mode ? .semibold : .regular))
                        Spacer()
                        if settings.proxySettings.mode == mode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        } header: {
            Text("代理方式")
        } footer: {
            Text(settings.proxySettings.mode.descriptionText)
        }
    }

    private var manualConfigSection: some View {
        Section {
            Picker("类型", selection: $settings.proxySettings.manualType) {
                ForEach(ManualProxyType.allCases) { type in
                    Text(type.displayTitle).tag(type)
                }
            }

            HStack {
                Text("服务器")
                    .frame(width: 60, alignment: .leading)
                TextField("如 127.0.0.1 或局域网 IP", text: $settings.proxySettings.host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.subheadline.monospaced())
            }

            HStack {
                Text("端口")
                    .frame(width: 60, alignment: .leading)
                TextField("如 1082 / 7890", text: $portText)
                    .keyboardType(.numberPad)
                    .font(.subheadline.monospaced())
                    .onChange(of: portText) { newValue in
                        let digits = newValue.filter(\.isNumber)
                        if digits != newValue {
                            portText = digits
                        }
                        if let parsed = Int(digits), (1...65535).contains(parsed) {
                            settings.proxySettings.port = parsed
                        } else {
                            settings.proxySettings.port = 0
                        }
                    }
            }

            if !settings.proxySettings.isManualConfigValid {
                Text("请填写有效地址，端口范围为 1 – 65535。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Text("账号")
                    .frame(width: 60, alignment: .leading)
                TextField("无则留空", text: $settings.proxySettings.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }

            HStack {
                Text("密码")
                    .frame(width: 60, alignment: .leading)
                SecureField("无则留空", text: $settings.proxySettings.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }

            Toggle("国内网站自动直连", isOn: $settings.proxySettings.bypassChinaDomains)
        } header: {
            Text("手动代理参数")
        } footer: {
            Text("开启「国内网站自动直连」后，国内站点与局域网自动直连，国外站点走代理，互不拖慢速度。")
        }
    }

    private var connectivityTestSection: some View {
        Section {
            Button {
                runTest()
            } label: {
                HStack {
                    if isTesting {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text("正在测试...")
                    } else {
                        Label("测试代理连接", systemImage: "bolt.horizontal.circle")
                    }
                }
            }
            .disabled(isTesting || (settings.proxySettings.mode == .manual && !settings.proxySettings.isManualConfigValid))

            if let result = testResult {
                HStack(spacing: 8) {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.success ? .green : .red)
                    Text(result.latencyMs.map { "\(result.message) · \($0) ms" } ?? result.message)
                        .font(.footnote)
                        .foregroundStyle(result.success ? Color.primary : Color.red)
                }
            }
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        let snapshot = settings.proxySettings
        Task {
            let outcome = await ProxyManager.testConnectivity(settings: snapshot)
            await MainActor.run {
                testResult = outcome
                isTesting = false
            }
        }
    }
}
