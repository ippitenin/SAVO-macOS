import SwiftUI

/// Окно настроек: папка загрузок, поведение и движок.
struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var engine = EngineStatus.shared

    /// Состояние кнопки «Скопировать отчёт».
    private enum ReportState { case idle, collecting, copied }
    @State private var reportState = ReportState.idle

    var body: some View {
        ZStack {
            AppBackground()
                .ignoresSafeArea()

            SettingsForm(title: L("settings.title")) {
                SettingsCard {
                    SettingsRow(title: L("settings.folder"),
                                help: L("settings.folder.help")) {
                        HStack(spacing: 8) {
                            Text(settings.downloadsFolder.lastPathComponent)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button(L("settings.folder.choose")) {
                                chooseFolder()
                            }
                            .dsGlassButton()
                            .controlSize(.small)
                        }
                    }
                }

                SettingsCard(header: L("settings.clipboard")) {
                    SettingsRow(title: L("settings.autopaste"),
                                help: L("settings.autopaste.help")) {
                        SettingsSwitch(isOn: $settings.autoPasteFromClipboard)
                    }
                }

                SettingsCard(header: L("settings.engine")) {
                    SettingsRow(title: L("settings.engine.version"),
                                help: L("settings.engine.help")) {
                        Text(engine.version ?? "—")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    CardDivider()
                    SettingsRow(title: L("settings.engine.update"),
                                subtitle: lastCheckText) {
                        HStack(spacing: 8) {
                            if engine.updating {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            if let status = engineStatusText {
                                Text(status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                            Button(L("settings.engine.updateButton")) {
                                Task { await engine.update(manual: true) }
                            }
                            .dsGlassButton()
                            .controlSize(.small)
                            .disabled(engine.updating)
                        }
                    }
                    CardDivider()
                    SettingsRow(title: L("settings.engine.autoUpdate"),
                                help: L("settings.engine.autoUpdate.help")) {
                        SettingsSwitch(isOn: $settings.autoUpdateEngine)
                    }
                }

                SettingsCard(header: L("settings.diagnostics")) {
                    SettingsRow(title: L("settings.diagnostics.report"),
                                help: L("settings.diagnostics.report.help")) {
                        HStack(spacing: 8) {
                            switch reportState {
                            case .collecting:
                                ProgressView()
                                    .controlSize(.small)
                            case .copied:
                                Text(L("settings.diagnostics.copied"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            case .idle:
                                EmptyView()
                            }
                            Button(L("settings.diagnostics.copy")) {
                                copyReport()
                            }
                            .dsGlassButton()
                            .controlSize(.small)
                            .disabled(reportState == .collecting)
                        }
                    }
                    CardDivider()
                    SettingsRow(title: L("settings.diagnostics.log")) {
                        Button(L("settings.diagnostics.showLog")) {
                            showLog()
                        }
                        .dsGlassButton()
                        .controlSize(.small)
                    }
                }
            }
        }
        .frame(width: 500, height: 640)
        .onAppear {
            engine.refreshVersion()
        }
    }

    /// Статус обновления справа от кнопки: фаза или итог последней попытки.
    private var engineStatusText: String? {
        switch engine.phase {
        case .checking: return L("settings.engine.checking")
        case .downloading(let version): return L("settings.engine.downloading", version)
        case .installing: return L("settings.engine.installing")
        case .idle: return engine.lastUpdateResult
        }
    }

    /// «Последняя проверка: 28.09, 16:40» под заголовком строки.
    private var lastCheckText: String? {
        engine.lastCheck.map {
            L("settings.engine.lastCheck",
              $0.formatted(.dateTime.day().month(.twoDigits).hour().minute()))
        }
    }

    /// Собирает отчёт для отладки и кладёт его в буфер обмена.
    /// Сбор занимает секунды: внутри два запуска движка.
    private func copyReport() {
        reportState = .collecting
        Task {
            let facts = await DiagnosticsReport.collect()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(DiagnosticsReport.render(facts), forType: .string)
            reportState = .copied
        }
    }

    /// Показывает журнал движка в Finder; нет журнала — открывает его папку.
    private func showLog() {
        let log = EngineLog.fileURL
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            try? FileManager.default.createDirectory(
                at: EngineLog.defaultDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(EngineLog.defaultDirectory)
        }
    }

    /// Выбор папки загрузок через системный диалог.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.downloadsFolder
        if panel.runModal() == .OK, let url = panel.url {
            settings.downloadsFolder = url
        }
    }
}
