import DiskBloomCore
import SwiftUI

struct ContentView: View {
    @StateObject private var store = ScanStore()
    @StateObject private var fullDiskAccess = FullDiskAccessController()
    @State private var showsPermissionSetup = false
    @State private var pendingFullScan = false
    @State private var didCheckStartupPermission = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                store: store,
                fullDiskAccessGranted: fullDiskAccess.isGranted,
                requestFullScan: requestFullScan,
                requestPermissionSetup: presentPermissionSetup
            )
                .frame(width: 270)
            Rectangle()
                .fill(BloomTheme.border)
                .frame(width: 1)
            Group {
                if let result = store.result {
                    DashboardView(result: result, store: store)
                } else {
                    WelcomeView(store: store, requestFullScan: requestFullScan)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BloomTheme.background)
        }
        .frame(minWidth: 1080, minHeight: 720)
        .background(BloomTheme.background)
        .alert(item: $store.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("확인")))
        }
        .sheet(isPresented: $showsPermissionSetup) {
            FullDiskAccessSetupView(
                controller: fullDiskAccess,
                willStartScan: pendingFullScan,
                verifyPermission: verifyPermissionAndContinue,
                continueWithLimitedAccess: continueWithLimitedAccess
            )
        }
        .onAppear {
            guard !didCheckStartupPermission else { return }
            didCheckStartupPermission = true
            if fullDiskAccess.refresh() {
                store.startAutomaticScanIfNeeded()
            } else {
                pendingFullScan = store.needsInitialScan
                showsPermissionSetup = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .diskBloomChooseFolder)) { _ in
            store.chooseFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .diskBloomRescan)) { _ in
            requestFullScan()
        }
    }

    private func requestFullScan() {
        if fullDiskAccess.refresh() {
            store.refreshAllLocalStorage()
        } else {
            pendingFullScan = true
            showsPermissionSetup = true
        }
    }

    private func presentPermissionSetup() {
        pendingFullScan = store.needsInitialScan
        fullDiskAccess.refresh()
        showsPermissionSetup = true
    }

    private func verifyPermissionAndContinue() {
        guard fullDiskAccess.refresh(showFailureMessage: true) else { return }
        showsPermissionSetup = false
        if pendingFullScan {
            pendingFullScan = false
            store.refreshAllLocalStorage()
        }
    }

    private func continueWithLimitedAccess() {
        showsPermissionSetup = false
        if pendingFullScan {
            pendingFullScan = false
            store.refreshAllLocalStorage()
        }
    }
}

private struct FullDiskAccessSetupView: View {
    @ObservedObject var controller: FullDiskAccessController
    let willStartScan: Bool
    let verifyPermission: () -> Void
    let continueWithLimitedAccess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(BloomTheme.mint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("처음 한 번만 권한을 설정해 주세요")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(BloomTheme.text)
                    Text("스캔 도중 폴더별 권한창이 반복되지 않게 합니다.")
                        .font(.system(size: 13))
                        .foregroundStyle(BloomTheme.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                permissionStep("1", "‘시스템 설정 열기’를 누릅니다.")
                permissionStep("2", "전체 디스크 접근 권한에서 DiskBloom을 켭니다. 목록에 없으면 +로 /Applications/DiskBloom.app을 추가합니다.")
                permissionStep("3", "이 창으로 돌아와 ‘권한 확인’을 누릅니다.")
            }
            .padding(16)
            .background(BloomTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("macOS 정책상 앱이 이 권한을 자동 승인할 수는 없습니다. 설치된 /Applications/DiskBloom.app에 한 번 허용하면 이후 스캔부터 유지됩니다.")
                .font(.system(size: 11))
                .foregroundStyle(BloomTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let message = controller.statusMessage {
                Label(message, systemImage: controller.isGranted ? "checkmark.circle.fill" : "info.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(controller.isGranted ? BloomTheme.mint : BloomTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("시스템 설정 열기") {
                    controller.openSystemSettings()
                }
                .buttonStyle(.borderedProminent)
                .tint(BloomTheme.mint)

                Button("권한 확인") {
                    verifyPermission()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(willStartScan ? "제한된 권한으로 스캔" : "나중에") {
                    continueWithLimitedAccess()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BloomTheme.secondary)
            }
        }
        .padding(26)
        .frame(width: 560)
        .background(BloomTheme.background)
    }

    private func permissionStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: 0x07110E))
                .frame(width: 20, height: 20)
                .background(BloomTheme.mint)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BloomTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var store: ScanStore
    let fullDiskAccessGranted: Bool
    let requestFullScan: () -> Void
    let requestPermissionSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BloomLogo(size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DiskBloom")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(BloomTheme.text)
                    Text("LOCAL DISK EXPLORER")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(BloomTheme.mint)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 26)

            Button(action: requestFullScan) {
                Label("전체 다시 스캔", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(BloomTheme.mint)
                    .foregroundStyle(Color(hex: 0x07110E))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("전체 로컬 저장소 다시 스캔")
            .disabled(store.isScanning)
            .opacity(store.isScanning ? 0.55 : 1)
            .padding(.horizontal, 16)

            Button(action: store.chooseFolder) {
                Label("폴더 직접 선택", systemImage: "folder.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(BloomTheme.panelRaised)
                    .foregroundStyle(BloomTheme.text)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("폴더 직접 선택")
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Text("저장된 영역")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(BloomTheme.muted)
                .padding(.horizontal, 20)
                .padding(.top, 26)
                .padding(.bottom, 10)

            if store.indexedLocations.isEmpty {
                Text(store.isScanning ? "첫 전체 분석을 진행하고 있습니다" : "저장된 분석 결과가 없습니다")
                    .font(.system(size: 10))
                    .foregroundStyle(BloomTheme.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.indexedLocations) { location in
                            IndexedLocationButton(
                                location: location,
                                selected: store.selectedLocationID == location.id,
                                action: { store.selectLocation(location.id) }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()

            if store.isScanning {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                            .tint(BloomTheme.mint)
                        Text("스캔 중")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("중지") { store.stopScan() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BloomTheme.coral)
                    }
                    Text("\(DiskBloomFormat.count(store.progress.items))개 항목")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(BloomTheme.text)
                    Text(store.progress.currentPath)
                        .font(.system(size: 10))
                        .foregroundStyle(BloomTheme.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(14)
                .background(BloomTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }

            VStack(alignment: .leading, spacing: 7) {
                Button(action: requestPermissionSetup) {
                    Label(
                        fullDiskAccessGranted ? "전체 디스크 접근 허용됨" : "전체 디스크 접근 설정",
                        systemImage: fullDiskAccessGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(fullDiskAccessGranted ? BloomTheme.mint : BloomTheme.coral)
                .disabled(fullDiskAccessGranted)
                Label("읽기 전용 스캔", systemImage: "eye.fill")
                Label("삭제는 휴지통으로", systemImage: "trash.slash.fill")
                Label("데이터 외부 전송 없음", systemImage: "lock.fill")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(BloomTheme.muted)
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
        }
        .background(BloomTheme.sidebar)
    }
}

private struct WelcomeView: View {
    @ObservedObject var store: ScanStore
    let requestFullScan: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            BloomLogo(size: 104)
            VStack(spacing: 10) {
                Text(store.isScanning ? "로컬 저장소를 처음 분석하는 중" : "저장된 분석 결과가 없습니다")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(BloomTheme.text)
                Text(store.isScanning
                     ? "이번 한 번만 전체를 읽고 저장합니다. 다음 실행부터는 캐시가 즉시 열립니다."
                     : "전체 로컬 저장소 분석을 시작해 공간 지도를 만드세요.")
                    .font(.system(size: 14))
                    .foregroundStyle(BloomTheme.secondary)
            }

            if store.isScanning {
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                            .tint(BloomTheme.mint)
                        Text("\(DiskBloomFormat.count(store.progress.items))개 항목")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(BloomTheme.text)
                        Spacer()
                        Button("중지") { store.stopScan() }
                            .buttonStyle(.plain)
                            .foregroundStyle(BloomTheme.coral)
                    }
                    Text(store.progress.currentPath)
                        .font(.system(size: 10))
                        .foregroundStyle(BloomTheme.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Divider().overlay(BloomTheme.border)
                    Label("iCloud·CloudStorage·네트워크 볼륨 제외", systemImage: "icloud.slash.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(BloomTheme.mint)
                }
                .padding(18)
                .frame(width: 520)
                .bloomPanel()
            } else {
                Button(action: requestFullScan) {
                    Label("전체 로컬 저장소 분석", systemImage: "externaldrive.connected.to.line.below")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(BloomTheme.mint)
                        .foregroundStyle(Color(hex: 0x07110E))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(40)
    }
}

private struct DashboardView: View {
    let result: ScanResult
    @ObservedObject var store: ScanStore
    @State private var focusStack: [DiskNode]
    @State private var selected: DiskNode?
    @State private var hovered: DiskNode?
    @State private var listMode: NodeListMode = .children
    @State private var query = ""
    @State private var pendingTrash: DiskNode?

    init(result: ScanResult, store: ScanStore) {
        self.result = result
        self.store = store
        _focusStack = State(initialValue: [result.root])
        _selected = State(initialValue: result.root)
    }

    private var focus: DiskNode { focusStack.last ?? result.root }

    private var listNodes: [DiskNode] {
        let source = listMode == .children ? focus.children : result.largestFiles
        guard !query.isEmpty else { return source }
        return source.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                dashboardHeader
                metrics
                HStack(alignment: .top, spacing: 16) {
                    chartPanel
                        .frame(minWidth: 530, minHeight: 470)
                    InspectorView(
                        node: hovered ?? selected ?? focus,
                        focus: focus,
                        root: result.root,
                        canEnter: canEnter(hovered ?? selected),
                        onEnter: { if let node = hovered ?? selected { enter(node) } },
                        onReveal: { if let node = hovered ?? selected { store.reveal(node) } },
                        onPreview: { if let node = hovered ?? selected { store.preview(node) } },
                        onTrash: { if let node = hovered ?? selected { pendingTrash = node } }
                    )
                    .frame(width: 300)
                }
                nodeListPanel
            }
            .padding(22)
        }
        .alert(item: $pendingTrash) { node in
            Alert(
                title: Text("휴지통으로 이동할까요?"),
                message: Text("‘\(node.name)’\n\n즉시 삭제하지 않고 macOS 휴지통으로 이동합니다."),
                primaryButton: .destructive(Text("휴지통으로 이동")) { store.moveToTrash(node) },
                secondaryButton: .cancel(Text("취소"))
            )
        }
        .onChange(of: result.root.id) { _, _ in
            withAnimation(.spring(response: 0.44, dampingFraction: 0.86)) {
                focusStack = [result.root]
                selected = result.root
                hovered = nil
                query = ""
            }
        }
    }

    private var dashboardHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                exitOneLevel()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 32, height: 32)
                    .background(BloomTheme.panel)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(focusStack.count <= 1)
            .opacity(focusStack.count <= 1 ? 0.35 : 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    ForEach(Array(focusStack.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(BloomTheme.muted)
                        }
                        Button(node.name) {
                            withAnimation(.spring(response: 0.44, dampingFraction: 0.86)) {
                                focusStack = Array(focusStack.prefix(index + 1))
                                selected = node
                                hovered = nil
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: index == focusStack.count - 1 ? .semibold : .regular))
                        .foregroundStyle(index == focusStack.count - 1 ? BloomTheme.text : BloomTheme.secondary)
                    }
                }
                Text(focus.path)
                    .font(.system(size: 10))
                    .foregroundStyle(BloomTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("diskbloom.focus.path")
            }
            Spacer()
            if result.unreadableCount > 0 {
                Button {
                    store.openFullDiskAccessSettings()
                } label: {
                    Label("읽기 실패 \(result.unreadableCount)", systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BloomTheme.amber)
                }
                .buttonStyle(.plain)
                .help("일부 폴더는 개인정보 보호 설정 때문에 읽지 못했습니다. 클릭하여 전체 디스크 접근 권한 설정을 엽니다.")
            }
            Button {
                NotificationCenter.default.post(name: .diskBloomRescan, object: nil)
            } label: {
                Label("전체 갱신", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(BloomTheme.panel)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            MetricCard(title: "사용 공간", value: DiskBloomFormat.bytes(focus.size), detail: focus.name, icon: "internaldrive.fill", tint: BloomTheme.mint)
            MetricCard(title: "파일", value: DiskBloomFormat.count(focus.fileCount), detail: "분석된 파일", icon: "doc.fill", tint: BloomTheme.blue)
            MetricCard(title: "폴더", value: DiskBloomFormat.count(focus.folderCount), detail: "하위 폴더 포함", icon: "folder.fill", tint: BloomTheme.amber)
            MetricCard(title: "스캔 시간", value: DiskBloomFormat.duration(result.elapsed), detail: result.scannedAt.formatted(date: .omitted, time: .shortened), icon: "timer", tint: BloomTheme.violet)
        }
    }

    private var chartPanel: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("공간 지도")
                        .font(.system(size: 16, weight: .bold))
                    Text("조각 클릭 · 안으로  /  중앙 클릭 · 한 단계 밖으로")
                        .font(.system(size: 10))
                        .foregroundStyle(BloomTheme.secondary)
                }
                Spacer()
            }
            .padding(18)

            SunburstView(
                root: focus,
                selected: $selected,
                hovered: $hovered,
                canExit: focusStack.count > 1,
                onEnter: enter,
                onExit: exitOneLevel
            )
                .padding(10)
                .frame(minHeight: 390)
        }
        .bloomPanel()
    }

    private var nodeListPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("목록", selection: $listMode) {
                    ForEach(NodeListMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)

                Spacer()
                TextField("이름 또는 경로 검색", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 12)
                    .frame(width: 230, height: 30)
                    .background(BloomTheme.panelRaised)
                    .clipShape(Capsule())
                Text("\(listNodes.count)개")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(BloomTheme.secondary)
            }
            .padding(14)

            Divider().overlay(BloomTheme.border)

            if listNodes.isEmpty {
                ContentUnavailableView("표시할 항목 없음", systemImage: "tray", description: Text("검색어를 바꾸거나 다른 폴더를 선택하세요."))
                    .frame(height: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(listNodes.prefix(300)) { node in
                            NodeRow(
                                node: node,
                                relativeTo: focus,
                                selected: selected?.id == node.id,
                                onSelect: { selected = node },
                                onEnter: { enter(node) },
                                onReveal: { store.reveal(node) },
                                onPreview: { store.preview(node) },
                                onTrash: { pendingTrash = node },
                                canTrash: DiskBloomDeletionPolicy.canMoveToTrash(node, root: result.root)
                            )
                        }
                    }
                    .padding(8)
                }
                .frame(height: 300)
            }
        }
        .bloomPanel()
    }

    private func canEnter(_ node: DiskNode?) -> Bool {
        guard let node, node.isDirectory, node.url != nil, !node.children.isEmpty else { return false }
        return node.id != focus.id
    }

    private func enter(_ node: DiskNode) {
        guard canEnter(node) else { return }
        withAnimation(.spring(response: 0.46, dampingFraction: 0.84, blendDuration: 0.08)) {
            focusStack.append(node)
            selected = node
            hovered = nil
        }
    }

    private func exitOneLevel() {
        guard focusStack.count > 1 else { return }
        withAnimation(.spring(response: 0.46, dampingFraction: 0.86, blendDuration: 0.08)) {
            focusStack.removeLast()
            selected = focusStack.last
            hovered = nil
        }
    }
}

private enum NodeListMode: String, CaseIterable, Identifiable {
    case children = "현재 폴더"
    case largest = "대용량 파일"
    var id: String { rawValue }
}

private struct InspectorView: View {
    let node: DiskNode
    let focus: DiskNode
    let root: DiskNode
    let canEnter: Bool
    let onEnter: () -> Void
    let onReveal: () -> Void
    let onPreview: () -> Void
    let onTrash: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: node.kind == .folder ? "folder.fill" : (node.kind == .aggregate ? "circle.grid.3x3.fill" : "doc.fill"))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(node.kind == .folder ? BloomTheme.amber : BloomTheme.blue)
                    .frame(width: 44, height: 44)
                    .background(BloomTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Spacer()
                Text(String(format: "%.1f%%", node.fraction(of: focus.size) * 100))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(BloomTheme.mint)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(node.name)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(BloomTheme.text)
                    .lineLimit(3)
                if !node.path.isEmpty {
                    Text(node.path)
                        .font(.system(size: 10))
                        .foregroundStyle(BloomTheme.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }

            Text(DiskBloomFormat.bytes(node.size))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(BloomTheme.text)

            VStack(spacing: 9) {
                InspectorLine(label: "파일", value: DiskBloomFormat.count(node.fileCount))
                InspectorLine(label: "폴더", value: DiskBloomFormat.count(node.folderCount))
                if let date = node.modifiedAt {
                    InspectorLine(label: "수정", value: date.formatted(date: .abbreviated, time: .omitted))
                }
                InspectorLine(label: "전체 대비", value: String(format: "%.1f%%", node.fraction(of: root.size) * 100))
            }

            Spacer()

            if canEnter {
                Button(action: onEnter) {
                    Label("폴더 안으로", systemImage: "arrow.down.right.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(BloomTheme.mint)
                        .foregroundStyle(Color(hex: 0x07110E))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                InspectorAction(icon: "eye.fill", title: "미리보기", action: onPreview)
                InspectorAction(icon: "scope", title: "Finder", action: onReveal)
            }

            if DiskBloomDeletionPolicy.canMoveToTrash(node, root: root) {
                Button(action: onTrash) {
                    Label("휴지통으로 이동", systemImage: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(BloomTheme.coral.opacity(0.12))
                        .foregroundStyle(BloomTheme.coral)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .bloomPanel()
    }
}

private struct NodeRow: View {
    let node: DiskNode
    let relativeTo: DiskNode
    let selected: Bool
    let onSelect: () -> Void
    let onEnter: () -> Void
    let onReveal: () -> Void
    let onPreview: () -> Void
    let onTrash: () -> Void
    let canTrash: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: node.kind == .folder ? "folder.fill" : (node.kind == .aggregate ? "square.stack.3d.up.fill" : "doc.fill"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(node.kind == .folder ? BloomTheme.amber : BloomTheme.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(node.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BloomTheme.text)
                    .lineLimit(1)
                Text(node.path.isEmpty ? "묶음 항목" : node.path)
                    .font(.system(size: 9))
                    .foregroundStyle(BloomTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 14)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.05))
                    Capsule()
                        .fill(BloomTheme.mint.opacity(0.65))
                        .frame(width: max(2, proxy.size.width * node.fraction(of: relativeTo.size)))
                }
            }
            .frame(width: 110, height: 5)
            Text(DiskBloomFormat.bytes(node.size))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(BloomTheme.secondary)
                .frame(width: 88, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(selected ? BloomTheme.panelRaised : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onTapGesture(count: 2, perform: onEnter)
        .contextMenu {
            Button("Quick Look", action: onPreview)
            Button("Finder에서 보기", action: onReveal)
            if canTrash {
                Divider()
                Button("휴지통으로 이동", role: .destructive, action: onTrash)
            }
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(BloomTheme.muted)
                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(BloomTheme.text)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.18), value: value)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(BloomTheme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .bloomPanel()
    }
}

private struct InspectorLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(BloomTheme.muted)
            Spacer()
            Text(value).foregroundStyle(BloomTheme.secondary)
        }
        .font(.system(size: 10, weight: .medium))
    }
}

private struct InspectorAction: View {
    let icon: String
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(BloomTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .foregroundStyle(BloomTheme.text)
    }
}

private struct IndexedLocationButton: View {
    let location: IndexedLocation
    let selected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: location.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? BloomTheme.mint : BloomTheme.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    Text(location.detail)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(BloomTheme.muted)
                }
                Spacer()
                if selected {
                    Circle().fill(BloomTheme.mint).frame(width: 5, height: 5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(selected ? BloomTheme.panelRaised : (isHovered ? Color.white.opacity(0.045) : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel("\(location.title), \(location.detail)")
        .accessibilityIdentifier("diskbloom.location.\(location.id)")
        .foregroundStyle(selected ? BloomTheme.text : BloomTheme.secondary)
        .padding(.horizontal, 8)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.easeOut(duration: 0.16), value: selected)
    }
}

struct BloomLogo: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(BloomTheme.panelRaised)
            Circle()
                .trim(from: 0.02, to: 0.30)
                .stroke(BloomTheme.mint, style: StrokeStyle(lineWidth: size * 0.105, lineCap: .round))
                .rotationEffect(.degrees(-74))
                .padding(size * 0.14)
            Circle()
                .trim(from: 0.06, to: 0.50)
                .stroke(BloomTheme.blue, style: StrokeStyle(lineWidth: size * 0.10, lineCap: .round))
                .rotationEffect(.degrees(38))
                .padding(size * 0.28)
            Circle().fill(BloomTheme.amber).frame(width: size * 0.16, height: size * 0.16)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.white.opacity(0.08)))
    }
}
