//
//  DuplicatesView.swift
//  SystemCleaner
//
//  Multi-stage duplicate file finder UI backed by DuplicateDetectionEngine.
//

import SwiftUI

struct DuplicatesView: View {
    @ObservedObject var viewModel: CleanerViewModel
    @State private var showTrashConfirmation = false

    private let minSizeOptions = [10, 100, 1024, 10240]

    var body: some View {
        VStack(spacing: 0) {
            controlsBar
            Divider()

            if viewModel.isScanningDuplicates {
                scanProgressView
            } else if viewModel.duplicateGroups.isEmpty {
                ContentUnavailableView {
                    Label("Duplicate File Finder", systemImage: "doc.on.doc")
                } description: {
                    Text("Uses exact byte-size bucketing, partial hashing, and full streaming SHA-256 verification to find true binary duplicates.")
                } actions: {
                    Button("Scan Selected Folders") {
                        viewModel.startDuplicateScan()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 0) {
                    selectionToolbar
                    Divider()
                    List(viewModel.duplicateGroups) { group in
                        Section {
                            ForEach(group.files) { file in
                                HStack(spacing: 10) {
                                    Button {
                                        viewModel.toggleDuplicateFile(groupID: group.id, fileID: file.id)
                                    } label: {
                                        Image(systemName: file.isSelected ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(file.isSelected ? Color.accentColor : Color.secondary)
                                    }
                                    .buttonStyle(.plain)

                                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                                        .resizable()
                                        .frame(width: 20, height: 20)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name)
                                            .font(.subheadline.weight(.medium))
                                        Text(file.url.path)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Spacer()

                                    Text(file.modifiedDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Button {
                                        CleanActionService.revealInFinder(file.url)
                                    } label: {
                                        Image(systemName: "magnifyingglass.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Reveal in Finder")
                                }
                                .padding(.vertical, 2)
                            }
                        } header: {
                            HStack {
                                Text("\(group.files.count) identical files")
                                    .font(.headline)
                                Spacer()
                                Text("\(ByteFormatter.format(group.byteSize)) each • \(ByteFormatter.format(group.totalWastedBytes)) wasted")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let message = viewModel.duplicatesStatusMessage {
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
        .navigationTitle("Duplicates")
        .confirmationDialog("Move Selected Duplicates to Trash?", isPresented: $showTrashConfirmation, titleVisibility: .visible) {
            Button("Move \(ByteFormatter.format(viewModel.totalSelectedDuplicateBytes)) to Trash", role: .destructive) {
                Task { await viewModel.trashSelectedDuplicates() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(viewModel.duplicateRoots, id: \.self) { url in
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                                .font(.caption)
                            Text(url.lastPathComponent)
                                .font(.caption)
                            if viewModel.duplicateRoots.count > 1 {
                                Button {
                                    viewModel.duplicateRoots.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }

            Button {
                let picked = CleanActionService.openFolderPicker(canChooseMultiple: true)
                for url in picked where !viewModel.duplicateRoots.contains(url) {
                    viewModel.duplicateRoots.append(url)
                }
            } label: {
                Label("Add Folder", systemImage: "plus")
            }
            .buttonStyle(.bordered)

            Picker("Min", selection: $viewModel.duplicateMinSizeKB) {
                ForEach(minSizeOptions, id: \.self) { kb in
                    Text(kb >= 1024 ? "\(kb / 1024) MB+" : "\(kb) KB+").tag(kb)
                }
            }
            .frame(width: 115)

            Button("Scan") {
                viewModel.startDuplicateScan()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isScanningDuplicates || viewModel.duplicateRoots.isEmpty)
        }
        .padding(14)
    }

    private var selectionToolbar: some View {
        HStack(spacing: 12) {
            Text("Auto-select:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Keep Oldest") {
                viewModel.autoSelectDuplicates(keepNewest: false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Keep Newest") {
                viewModel.autoSelectDuplicates(keepNewest: true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Button {
                showTrashConfirmation = true
            } label: {
                Label("Move Selected to Trash (\(ByteFormatter.format(viewModel.totalSelectedDuplicateBytes)))", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.totalSelectedDuplicateBytes == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var scanProgressView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            if let prog = viewModel.duplicateProgress {
                Text(prog.stage.rawValue)
                    .font(.headline)
                Text("Examined: \(prog.filesExamined) • Candidate Groups: \(prog.candidateGroups)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !prog.currentPath.isEmpty {
                    Text(prog.currentPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 40)
                }
            }
            Button("Cancel") {
                viewModel.cancelDuplicateScan()
            }
            .buttonStyle(.bordered)
            Spacer()
        }
    }
}
