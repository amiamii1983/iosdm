import SwiftUI
import UIKit

struct NewDownloadSheet: View {
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var customFileName = ""
    @State private var threadCount = 4
    @State private var startImmediately = true
    @State private var taskProxyChoice: TaskProxyChoice = .followGlobal

    @State private var showAdvancedHeaders = false
    @State private var userAgent = ""
    @State private var referer = ""
    @State private var cookie = ""
    @State private var authorization = ""
    @State private var extraHeadersText = ""

    @State private var clipboardHasURL = false
    @State private var validationError: String?

    private enum TaskProxyChoice: String, CaseIterable, Identifiable {
        case followGlobal
        case auto
        case manual
        case direct

        var id: String { rawValue }

        var overrideMode: ProxyMode? {
            switch self {
            case .followGlobal: return nil
            case .auto: return .auto
            case .manual: return .manual
            case .direct: return .direct
            }
        }
    }

    private var detectedProviderName: String? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        return CloudLinkResolver.providerName(for: url)
    }

    var body: some View {
        CompatNavigationStack {
            Form {
                if clipboardHasURL && urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        Button {
                            pasteFromClipboard()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.on.clipboard.fill")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("检测到剪贴板中有下载链接")
                                        .font(.subheadline.weight(.semibold))
                                    Text("轻点此处快速填入 iosdm")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("下载链接 (HTTP / HTTPS / 国外网盘)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("粘贴") {
                                pasteFromClipboard()
                            }
                            .font(.caption.weight(.medium))
                            if !urlText.isEmpty {
                                Button("清空") {
                                    urlText = ""
                                    validationError = nil
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }

                        CompatMultilineField(
                            placeholder: "https://example.com/file.zip",
                            text: $urlText,
                            minLines: 2,
                            maxLines: 5
                        )
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(.footnote.monospaced())
                        .onChange(of: urlText) { _ in
                            validationError = nil
                        }

                        if let provider = detectedProviderName {
                            Label("已识别 \(provider) 链接，iosdm 将自动解析真实文件直链", systemImage: "icloud.and.arrow.down")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }

                    TextField("自定义文件名（留空则自动获取）", text: $customFileName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } footer: {
                    Text("支持 http / https 直链，以及 MediaFire、Google Drive、Dropbox、Pixeldrain、Gofile、OneDrive、GitHub 等国外热门网盘解析与断点续传。")
                }

                if let validationError {
                    Section {
                        Label(validationError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("下载参数") {
                    Picker("分片线程数", selection: $threadCount) {
                        ForEach(AppSettings.supportedThreadCounts, id: \.self) { count in
                            Text("\(count) 线程").tag(count)
                        }
                    }

                    Picker("网络代理", selection: $taskProxyChoice) {
                        Text("跟随全局（\(settings.proxySettings.mode.shortTitle)）").tag(TaskProxyChoice.followGlobal)
                        Text("自动（系统 / VPN）").tag(TaskProxyChoice.auto)
                        Text("手动代理").tag(TaskProxyChoice.manual)
                        Text("直连").tag(TaskProxyChoice.direct)
                    }

                    Toggle("添加后立即开始下载", isOn: $startImmediately)
                }

                Section {
                    DisclosureGroup("自定义请求头（防盗链 / 登录态）", isExpanded: $showAdvancedHeaders) {
                        TextField("Referer（来源页 URL）", text: $referer)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .font(.footnote)

                        TextField("Cookie", text: $cookie)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .font(.footnote)

                        TextField("User-Agent（留空使用标准浏览器 UA）", text: $userAgent)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .font(.footnote)

                        TextField("Authorization（如 Bearer ...）", text: $authorization)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .font(.footnote)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("其他自定义 Header（每行一项，格式 Key: Value）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            CompatMultilineField(
                                placeholder: "X-Custom-Token: abc123",
                                text: $extraHeadersText,
                                minLines: 2,
                                maxLines: 4
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .font(.footnote.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("新建下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(startImmediately ? "开始下载" : "添加任务") {
                        submit()
                    }
                    .font(.body.weight(.semibold))
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                threadCount = settings.defaultThreadCount
                clipboardHasURL = UIPasteboard.general.hasURLs
            }
        }
    }

    private func pasteFromClipboard() {
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return
        }
        urlText = raw
        validationError = nil
    }

    private func buildHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        if !referer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers["Referer"] = referer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers["Cookie"] = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers["User-Agent"] = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !authorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers["Authorization"] = authorization.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for line in extraHeadersText.components(separatedBy: .newlines) {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty && !value.isEmpty {
                headers[key] = value
            }
        }
        return headers
    }

    private func submit() {
        do {
            try manager.addDownload(
                urlString: urlText,
                customFileName: customFileName.isEmpty ? nil : customFileName,
                threadCount: threadCount,
                customHeaders: buildHeaders(),
                proxyModeOverride: taskProxyChoice.overrideMode,
                startImmediately: startImmediately
            )
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}
