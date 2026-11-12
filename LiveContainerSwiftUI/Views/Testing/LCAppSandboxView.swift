import SwiftUI

struct LCAppSandboxView: View {
    @ObservedObject var model: LCAppModel
    @State private var selected = ""

    private var container: LCContainer? {
        model.uiContainers.first { $0.folderName == selected } ?? model.uiSelectedContainer ?? model.uiContainers.first
    }

    var body: some View {
        Group {
            if let container {
                LCContainerFilesView(root: container.containerURL, directory: container.containerURL)
                    .id(container.folderName)
                    .safeAreaInset(edge: .top) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("数据沙盒").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Menu {
                                ForEach(model.uiContainers, id: \.folderName) { item in
                                    Button(item.name == item.folderName ? "沙盒 " + String((model.uiContainers.firstIndex(of: item) ?? 0) + 1) : item.name) { selected = item.folderName }
                                }
                            } label: {
                                Label(container.name == container.folderName ? "切换沙盒" : container.name, systemImage: "chevron.up.chevron.down")
                                    .font(.subheadline).lineLimit(1).padding(.vertical, 8)
                            }
                        }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
                    }
            } else {
                LCToolEmptyState(title: "尚无数据容器", message: "首次启动 App 后会创建沙盒，再回到这里浏览文件。", symbol: "folder")
                    .navigationTitle("浏览沙盒")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    LCSandboxBackupsView(model: model, container: container?.folderName)
                } label: { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel("沙盒备份与比较")
            }
        }
    }
}
