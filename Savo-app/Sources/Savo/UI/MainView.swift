import SwiftUI

/// Корневая вью главного окна: mesh-фон и hero-зона, переключающаяся
/// по состоянию DownloadController.
struct MainView: View {
    @ObservedObject var controller: DownloadController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AppBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    header
                    URLInputView(controller: controller)
                    stateContent
                        .id(controller.state.caseKey)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 10)),
                            removal: .opacity
                        ))
                    HistorySectionView()
                        .padding(.top, 8)
                }
                .padding(.horizontal, DS.Spacing.section)
                .padding(.top, 52)
                .padding(.bottom, 24)
            }
            .animation(reduceMotion ? nil : DS.Anim.section, value: controller.state.caseKey)
        }
        .frame(minWidth: 520, minHeight: 600)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(L("app.name"))
                .font(.system(size: 32, weight: .bold))
            Text(L("main.tagline"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var stateContent: some View {
        switch controller.state {
        case .idle:
            idleHint
        case .fetchingInfo:
            fetchingCard
        case .ready(let info):
            VStack(spacing: 12) {
                VideoCardView(info: info)
                PresetPickerView(info: info) { preset in
                    controller.download(preset: preset)
                }
            }
        case .downloading(let progress):
            DownloadProgressView(progress: progress) {
                controller.cancelDownload()
            }
        case .done(let filePath, let info):
            DonePanelView(filePath: filePath, info: info) {
                controller.reset()
            }
        case .failed(let error):
            errorCard(error)
        }
    }

    private var idleHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(DS.rose)
                .dsBreathe()
            Text(L("main.hint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 48)
    }

    private var fetchingCard: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(L("state.fetching"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(L("action.cancel")) {
                controller.cancel()
            }
            .dsGlassButton()
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .glassSurface()
    }

    private func errorCard(_ error: SavoError) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(DS.marker)
            Text(error.message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let details = error.details {
                DisclosureGroup(L("error.detailsTitle")) {
                    Text(details)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .font(.caption)
            }
            Button(L("error.retry")) {
                controller.reset(keepURL: true)
            }
            .dsProminentButton()
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.cardPadding + 8)
        .glassSurface()
    }
}

/// Поле ввода ссылки с кнопкой «Вставить».
struct URLInputView: View {
    @ObservedObject var controller: DownloadController

    private var isBusy: Bool {
        controller.state.caseKey == "fetching" || controller.state.caseKey == "downloading"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
            TextField(L("input.placeholder"), text: $controller.urlText)
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit { controller.submit() }
                .disabled(isBusy)
            Button(L("input.paste")) {
                controller.pasteAndSubmit()
            }
            .dsGlassButton()
            .controlSize(.small)
            .disabled(isBusy)
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.vertical, 10)
        .glassCapsule()
    }
}
