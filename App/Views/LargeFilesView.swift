//
//  LargeFilesView.swift
//  SystemCleaner
//
//  Finds large files above a configurable threshold and moves selected items safely to Trash.
//

import SwiftUI

struct LargeFilesView: View {
    @ObservedObject var viewModel: CleanerViewModel
    @State private var searchText = ""
    @State private var showTrashConfirmation = false

    private let thresholds = [50, 100, 250, 500, 1024]

    private var selectedBytes: UInt64 {
        viewModel.largeFiles.filter(\.isSelected).reduce(0) { $0 + $1.byteSize }
    }

    private var filteredFiles: [LargeFileItem] {
        viewModel.largeFiles.filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) || $0.url.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controlsBar
            Divider()

            if viewModel.isScanningLargeFiles {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text(viewModel.largeFilesProgressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 40)
                    Button("Cancel Scan") {
                        viewModel.cancelLargeFilesScan()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            } else if viewModel.largeFiles.isEmpty {
                ContentUnavailableView {
                    Label("Large Files Finder", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text("Locate forgotten movies, disk images, archives, and oversized files taking up storage.")
                } actions: {
                    Button("Scan \(viewModel.largeFilesScopeURL.lastPathComponent)") {
                        viewModel.startLargeFilesScan()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List(filteredFiles) { item in
                    HStack(spacing: 10) {
                        Button {
                            viewModel.toggleLargeFile(item.id)
                        } label: {
                            Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)

                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                            .resizable()
                            .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(item.url.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        if let date = item.modifiedDate {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)
                        }

                        Text(ByteFormatter.format(item.byteSize))
                            .font(.subheadline.monospacedDigit().bold())
                            .frame(width: 90, alignment: .trailing)

                        Button {
                            CleanActionService.revealInFinder(item.url)
                        } label: {
                            Image(systemName: "magnifyingglass.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                    }
                    .padding(.vertical, 3)
                }
            }

            if let message = viewModel.largeFilesStatusMessage {
                Divider()
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text(message)
                        .font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .navigationTitle("Large Files")
        .confirmationDialog("Move Selected Large Files to Trash?", isPresented: $showTrashConfirmation, titleVisibility: .visible) {
            Button("Move \(ByteFormatter.format(selectedBytes)) to Trash", role: .destructive) {
                Task { await viewModel.trashSelectedLargeFiles() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 12) {
            Button {
                if let chosen = CleanActionService.openFolderPicker(canChooseMultiple: false).first {
                    viewModel.largeFilesScopeURL = chosen
                }
            } label: {
                Label(viewModel.largeFilesScopeURL.lastPathComponent, systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .help(viewModel.largeFilesScopeURL.path)

            Picker("Min Size", selection: $viewModel.largeFilesThresholdMB) {
                ForEach(thresholds, id: \.self) { mb in
                    Text(mb >= 1024 ? "1 GB+" : "\(mb) MB+").tag(mb)
                }
            }
            .frame(width: 150)

            TextField("Filter files...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

            Spacer()

            Button("Scan") {
                viewModel.startLargeFilesScan()
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isScanningLargeFiles)

            Button {
                showTrashConfirmation = true
            } label: {
                Label("Move to Trash (\(ByteFormatter.format(selectedBytes)))", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedBytes == 0)
        }
        .padding(14)
    }
}
