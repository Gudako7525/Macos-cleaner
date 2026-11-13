//
//  JunkCleanerView.swift
//  SystemCleaner
//
//  Categorized junk & cache scanner with item inspection and safe Move-to-Trash cleaning.
//

import SwiftUI

struct JunkCleanerView: View {
    @ObservedObject var viewModel: CleanerViewModel
    @State private var selectedCategory: JunkCategory? = .userCaches
    @State private var showCleanConfirmation = false
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            topToolbar

            Divider()

            if viewModel.junkItems.isEmpty && !viewModel.isScanningJunk {
                emptyState
            } else {
                HSplitView {
                    categoryList
                        .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)

                    itemDetailList
                        .frame(minWidth: 400)
                }
            }

            if let message = viewModel.junkStatusMessage {
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
        .navigationTitle("Junk Cleaner")
        .confirmationDialog(
            "Clean Selected Items?",
            isPresented: $showCleanConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean \(ByteFormatter.format(viewModel.totalSelectedJunkBytes))", role: .destructive) {
                Task { await viewModel.cleanSelectedJunk() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cache, log, and download items will be moved to Trash. Trash items will be permanently emptied.")
        }
    }

    private var topToolbar: some View {
        HStack(spacing: 12) {
            if viewModel.isScanningJunk {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scanning system junk...")
                        .font(.headline)
                    Text(viewModel.junkScanProgressPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Stop") {
                    viewModel.cancelJunkScan()
                }
                .buttonStyle(.bordered)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Junk & Cache Cleaner")
                        .font(.headline)
                    Text("Found \(ByteFormatter.format(viewModel.totalJunkBytes)) • Selected \(ByteFormatter.format(viewModel.totalSelectedJunkBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    viewModel.startJunkScan()
                } label: {
                    Label(viewModel.junkItems.isEmpty ? "Scan Now" : "Rescan", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)

                Button {
                    showCleanConfirmation = true
                } label: {
                    if viewModel.isCleaningJunk {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Clean Selected", systemImage: "trash")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.totalSelectedJunkBytes == 0 || viewModel.isCleaningJunk)
            }
        }
        .padding(14)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Ready to Scan Junk", systemImage: "sparkles")
        } description: {
            Text("Inspect user caches, application logs, browser caches, Xcode DerivedData, old installers, and Trash safely before removing.")
        } actions: {
            Button("Start Smart Scan") {
                viewModel.startJunkScan()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var categoryList: some View {
        List(JunkCategory.allCases, selection: $selectedCategory) { category in
            let catItems = viewModel.items(for: category)
            let catTotal = catItems.reduce(0) { $0 + $1.byteSize }
            let catSelected = catItems.filter(\.isSelected).reduce(0) { $0 + $1.byteSize }
            let allSelected = !catItems.isEmpty && catItems.allSatisfy(\.isSelected)

            HStack(spacing: 8) {
                Button {
                    viewModel.setCategorySelected(category, selected: !allSelected)
                } label: {
                    Image(systemName: allSelected ? "checkmark.square.fill" : (catSelected > 0 ? "minus.square.fill" : "square"))
                        .foregroundStyle(catSelected > 0 ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(catItems.isEmpty)

                Image(systemName: category.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.rawValue)
                        .font(.subheadline.weight(.medium))
                    Text("\(catItems.count) item(s)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(ByteFormatter.format(catTotal))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(catTotal > 0 ? .primary : .secondary)
            }
            .padding(.vertical, 4)
            .tag(category)
        }
    }

    private var itemDetailList: some View {
        let activeCategory = selectedCategory ?? .userCaches
        let filteredItems = viewModel.items(for: activeCategory).filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) || $0.url.path.localizedCaseInsensitiveContains(searchText)
        }

        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activeCategory.rawValue)
                        .font(.headline)
                    Text(activeCategory.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Filter...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            .padding(12)

            Divider()

            if filteredItems.isEmpty {
                Spacer()
                Text("No items found in \(activeCategory.rawValue).")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filteredItems) { item in
                    HStack(spacing: 10) {
                        Button {
                            viewModel.toggleJunkItem(item.id)
                        } label: {
                            Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)

                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                            .resizable()
                            .frame(width: 22, height: 22)

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

                        Text(ByteFormatter.format(item.byteSize))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Button {
                            CleanActionService.revealInFinder(item.url)
                        } label: {
                            Image(systemName: "magnifyingglass.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
