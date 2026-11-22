import SwiftUI

enum TaskFilterTab: String, CaseIterable, Identifiable {
    case all = "全部"
    case active = "下载中"
    case completed = "已完成"

    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedFilter: TaskFilterTab = .all
    @State private var searchText = ""
    @State private var showNewDownload = false
    @State private var showSettings = false
    @State private var showProxySettings = false
    @State private var selectedTaskId: UUID?

    private var filteredTasks: [DownloadTaskModel] {
        let base: [DownloadTaskModel]
        switch selectedFilter {
        case .all:
            base = manager.tasks
        case .active:
            base = manager.tasks.filter { $0.status != .completed }
        case .completed:
            base = manager.tasks.filter { $0.status == .completed }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.fileName.lowercased().contains(query) || $0.originalURL.lowercased().contains(query)
        }
    }

    private var activeCount: Int {
        manager.tasks.filter { $0.status != .completed }.count
    }

    private var completedCount: Int {
        manager.tasks.filter { $0.status == .completed }.count
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if horizontalSizeClass == .regular {
                    wideSplitLayout
                } else {
                    compactLayout
                }
            }

            // Minimal floating monitor (default OFF in Settings, zero cost when disabled or idle)
            DownloadMonitorOverlay()
        }
        .sheet(isPresented: $showNewDownload) {
            NewDownloadSheet()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showProxySettings) {
            ProxySettingsView()
        }
    }

    // MARK: - iPadOS Wide Split Layout (iOS 16+ NavigationSplitView, iOS 15 NavigationView)

    @ViewBuilder
    private var wideSplitLayout: some View {
        if #available(iOS 16.0, *) {
            NavigationSplitView {
                taskListContainer(isSplitMode: true)
                    .navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 500)
            } detail: {
                NavigationStack {
                    splitDetailContent
                }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationView {
                taskListContainer(isSplitMode: false)
                ContentUnavailableViewCompat(
                    title: "选择一个下载任务",
                    subtitle: "在左侧列表中点选任意任务，即可查看 iosdm 多线程分片进度、连接状态或预览导出文件。",
                    systemImage: "sidebar.left"
                )
            }
        }
    }

    @ViewBuilder
    private var splitDetailContent: some View {
        if let selectedTaskId,
           manager.tasks.contains(where: { $0.id == selectedTaskId }) {
            TaskDetailView(taskId: selectedTaskId) {
                self.selectedTaskId = nil
            }
            .id(selectedTaskId)
        } else {
            ContentUnavailableViewCompat(
                title: "选择一个下载任务",
                subtitle: "在左侧列表中点选任意任务，即可在此查看 iosdm 多线程分片进度、连接状态或预览导出文件。",
                systemImage: "sidebar.left"
            )
            .navigationTitle("下载详情")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - iPhone / Compact Layout

    private var compactLayout: some View {
        CompatNavigationStack {
            taskListContainer(isSplitMode: false)
        }
    }

    // MARK: - Shared Task List Container

    private func taskListContainer(isSplitMode: Bool) -> some View {
        VStack(spacing: 0) {
            Picker("筛选", selection: $selectedFilter) {
                Text("全部 (\(manager.tasks.count))").tag(TaskFilterTab.all)
                Text("进行中 (\(activeCount))").tag(TaskFilterTab.active)
                Text("已完成 (\(completedCount))").tag(TaskFilterTab.completed)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 6)
            .padding(.bottom, 8)

            if manager.activeDownloadCount > 0 {
                globalSpeedBar
            }

            if filteredTasks.isEmpty {
                emptyStateView
            } else if isSplitMode {
                List(selection: $selectedTaskId) {
                    ForEach(filteredTasks) { task in
                        rowContent(for: task)
                            .tag(task.id)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                leadingSwipeButtons(for: task)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                trailingSwipeButtons(for: task)
                            }
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                List {
                    ForEach(filteredTasks) { task in
                        NavigationLink {
                            TaskDetailView(taskId: task.id)
                        } label: {
                            rowContent(for: task)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            leadingSwipeButtons(for: task)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            trailingSwipeButtons(for: task)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("iosdm")
        .searchable(text: $searchText, prompt: "搜索文件名或链接")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("iosdm 设置")

                proxyToolbarMenu
            }

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !manager.tasks.isEmpty {
                    Menu {
                        if manager.tasks.contains(where: { $0.canResume }) {
                            Button {
                                manager.resumeAll()
                            } label: {
                                Label("全部继续", systemImage: "play.fill")
                            }
                        }
                        if manager.tasks.contains(where: { $0.canPause }) {
                            Button {
                                manager.pauseAll()
                            } label: {
                                Label("全部暂停", systemImage: "pause.fill")
                            }
                        }
                        if completedCount > 0 {
                            Divider()
                            Button(role: .destructive) {
                                manager.clearCompletedTasks(deleteFiles: false)
                                if let selectedTaskId,
                                   !manager.tasks.contains(where: { $0.id == selectedTaskId }) {
                                    self.selectedTaskId = nil
                                }
                            } label: {
                                Label("清空已完成记录", systemImage: "checklist")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }

                Button {
                    showNewDownload = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .accessibilityLabel("新建下载")
            }
        }
    }

    private var proxyToolbarMenu: some View {
        Menu {
            Section("iosdm 代理模式") {
                ForEach(ProxyMode.allCases) { mode in
                    Button {
                        settings.proxySettings.mode = mode
                    } label: {
                        if settings.proxySettings.mode == mode {
                            Label(mode.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(mode.displayTitle)
                        }
                    }
                }
            }

            Divider()

            Button {
                showProxySettings = true
            } label: {
                Label("小火箭状态与代理详细设置...", systemImage: "slider.horizontal.3")
            }
        } label: {
            if horizontalSizeClass == .regular {
                HStack(spacing: 4) {
                    Image(systemName: proxyIconName)
                    Text(settings.proxySettings.mode.shortTitle)
                        .font(.caption.weight(.medium))
                }
            } else {
                Image(systemName: proxyIconName)
            }
        }
        .accessibilityLabel("代理菜单（当前：\(settings.proxySettings.mode.shortTitle)）")
    }

    private var proxyIconName: String {
        switch settings.proxySettings.mode {
        case .auto: return "network"
        case .manual: return "lock.shield"
        case .direct: return "bolt.horizontal"
        }
    }

    private func rowContent(for task: DownloadTaskModel) -> some View {
        let shareURL: URL? = manager.completedFileExists(for: task)
            ? manager.completedFileURL(for: task)
            : nil
        return DownloadRowView(
            task: task,
            completedFileURL: shareURL,
            onPrimaryAction: {
                handlePrimaryAction(for: task)
            }
        )
    }

    @ViewBuilder
    private func leadingSwipeButtons(for task: DownloadTaskModel) -> some View {
        if task.canPause {
            Button {
                manager.pause(taskId: task.id)
            } label: {
                Label("暂停", systemImage: "pause.fill")
            }
            .tint(.orange)
        } else if task.canResume {
            Button {
                manager.startOrResume(taskId: task.id)
            } label: {
                Label("继续", systemImage: "play.fill")
            }
            .tint(.blue)
        }
    }

    @ViewBuilder
    private func trailingSwipeButtons(for task: DownloadTaskModel) -> some View {
        Button(role: .destructive) {
            if selectedTaskId == task.id {
                selectedTaskId = nil
            }
            manager.deleteTask(taskId: task.id, deleteLocalFile: true)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private var globalSpeedBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
            Text("iosdm 正在下载 \(manager.activeDownloadCount) 个任务")
                .font(.caption.weight(.medium))
            Spacer()
            Text(ByteFormatter.formatSpeed(manager.totalSpeedBytesPerSec))
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(.blue)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.08))
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: selectedFilter == .completed ? "checkmark.circle" : "arrow.down.doc")
                .font(.system(size: 52))
                .foregroundStyle(.blue.opacity(0.75))

            Text(emptyTitle)
                .font(.headline)

            Text(emptySubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            if selectedFilter != .completed {
                Button {
                    showNewDownload = true
                } label: {
                    Label("新建下载任务", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if !searchText.isEmpty { return "未找到匹配任务" }
        switch selectedFilter {
        case .all: return "暂无下载任务"
        case .active: return "没有进行中的下载"
        case .completed: return "还没有已完成的文件"
        }
    }

    private var emptySubtitle: String {
        if !searchText.isEmpty { return "尝试换个关键词搜索" }
        switch selectedFilter {
        case .all: return "iosdm 支持 HTTP / HTTPS、国外热门网盘解析、代理分流与断点续传，点击下方按钮添加链接。"
        case .active: return "所有下载任务均已完成，或点击右上角 + 添加新任务。"
        case .completed: return DeviceStorageText.emptyCompletedHint(customFolderName: settings.customDownloadFolderName)
        }
    }

    private func handlePrimaryAction(for task: DownloadTaskModel) {
        if task.canPause {
            manager.pause(taskId: task.id)
        } else if task.canResume {
            manager.startOrResume(taskId: task.id)
        }
    }
}
