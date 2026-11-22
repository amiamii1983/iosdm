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
                    splitRoutingSection
                }
                connectivityTestSection
            }
            .navigationTitle("iosdm 代理设置")
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
            .alert("已导入代理参数", isPresented: $importedToast) {
                Button("好", role: .cancel) {}
            } message: {
                Text("已将检测到的系统 / VPN 代理地址填入手动代理配置。")
            }
        }
    }

    private var systemStatusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(detectedInfo.hasAnyProxyOrVPN ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 10, height: 10)
                    Text(detectedInfo.summaryTitle)
                        .font(.subheadline.weight(.semibold))
                }

                ForEach(detectedInfo.detailLines, id: \.self) { line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            Button {
                detectedInfo = ProxyManager.detectSystemProxy()
                testResult = nil
            } label: {
                Label("刷新读取系统 / VPN 代理", systemImage: "arrow.clockwise")
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
                    Label("导入 \(host):\(port) 到手动代理", systemImage: "square.and.arrow.down")
                }
            }
        } header: {
            Text("当前系统与 VPN 代理状态")
        } footer: {
            Text("仅在打开本页或点击刷新时读取一次系统状态，后台不轮询、不耗电。开启 Shadowrocket、Surge、Quantumult X、Loon、Clash 等代理软件后，使用「自动」模式即可直接共享其国内外分流。")
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayTitle)
                                .foregroundStyle(.primary)
                                .font(.subheadline.weight(settings.proxySettings.mode == mode ? .semibold : .regular))
                        }
                        Spacer()
                        if settings.proxySettings.mode == mode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        } header: {
            Text("代理模式")
        } footer: {
            Text(settings.proxySettings.mode.descriptionText)
        }
    }

    private var manualConfigSection: some View {
        Section {
            Picker("代理协议", selection: $settings.proxySettings.manualType) {
                ForEach(ManualProxyType.allCases) { type in
                    Text(type.displayTitle).tag(type)
                }
            }

            HStack {
                Text("服务器")
                    .frame(width: 64, alignment: .leading)
                TextField("如 127.0.0.1 或局域网 IP", text: $settings.proxySettings.host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.subheadline.monospaced())
            }

            HStack {
                Text("端口")
                    .frame(width: 64, alignment: .leading)
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
                Text("请填写有效的代理服务器地址，且端口须在 1 – 65535 之间。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Text("用户名")
                    .frame(width: 64, alignment: .leading)
                TextField("选填", text: $settings.proxySettings.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }

            HStack {
                Text("密码")
                    .frame(width: 64, alignment: .leading)
                SecureField("选填", text: $settings.proxySettings.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
        } header: {
            Text("手动代理服务器")
        } footer: {
            Text("若本机代理软件开启了「代理共享」或本地端口，可填写 127.0.0.1 与对应端口，或填写局域网电脑/软路由的 HTTP 或 SOCKS5 代理。")
        }
    }

    private var splitRoutingSection: some View {
        Section {
            Toggle("国内网络与局域网自动直连", isOn: $settings.proxySettings.bypassChinaDomains)

            VStack(alignment: .leading, spacing: 6) {
                Text("自定义直连绕过域名（逗号或换行分隔）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CompatMultilineField(
                    placeholder: "如 *.example.com, 192.168.*",
                    text: $settings.proxySettings.customBypassRules,
                    minLines: 2,
                    maxLines: 4
                )
                .font(.caption.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            }
        } header: {
            Text("国内外分流保护")
        } footer: {
            Text("开启后，中国大陆常见域名（.cn 及主流国内站/CDN）和局域网地址将自动绕过手动代理高速直连，国外网盘走代理，互不影响。")
        }
    }

    private var connectivityTestSection: some View {
        Section("连通性测试") {
            Button {
                runTest()
            } label: {
                HStack {
                    if isTesting {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text("正在检测海外连通性...")
                    } else {
                        Label("测试当前代理海外连通性", systemImage: "bolt.horizontal.circle")
                    }
                }
            }
            .disabled(isTesting || (settings.proxySettings.mode == .manual && !settings.proxySettings.isManualConfigValid))

            if let result = testResult {
                HStack(spacing: 8) {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.success ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.message)
                            .font(.footnote)
                            .foregroundStyle(result.success ? Color.primary : Color.red)
                        if let ms = result.latencyMs {
                            Text("响应耗时：\(ms) ms")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
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
