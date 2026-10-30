import AppKit
import FileveroCore
import SwiftUI

// MARK: - JobExecutionQueueView: Batch Processing Task Monitor

public struct JobExecutionQueueView: View {
    @ObservedObject public var state: AppSessionController

    public init(state: AppSessionController) {
        self.state = state
    }

    public static func isRelevant(_ queue: JobQueueState) -> Bool {
        queue.jobs.count > 1 || queue.jobs.contains { $0.status.isFinished }
    }

    public var body: some View {
        let jobs = state.queue.jobs
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Queue").font(.system(size: 13, weight: .semibold))
                Text("\(jobs.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if jobs.contains(where: \.status.canRetry) {
                    Button("Retry all") { state.retry(nil) }
                }
                if jobs.contains(where: \.status.isFinished) {
                    Button("Clear finished") { state.clearFinishedJobs() }
                }
            }
            .padding(14)

            Divider()

            VStack(spacing: 0) {
                ForEach(jobs) {
                    JobRow(job: $0, state: state)
                }
            }
            .padding(.vertical, 6)
        }
        .fileveroCard(radius: 18)
    }
}

private struct JobRow: View {
    let job: QueueJob
    @ObservedObject var state: AppSessionController

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: job.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                status.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch job.status {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case .interrupted:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var status: some View {
        switch job.status {
        case .waiting:
            Text("Waiting")
        case .running:
            LText(state.progressLabel.isEmpty ? "Processing…" : state.progressLabel)
        case .done(let outputs):
            outputs.count == 1
                ? LText("Saved as \(outputs[0].lastPathComponent)") : LText("\(outputs.count) files saved")
        case .failed(let message):
            LText(message)
        case .cancelled:
            Text("Cancelled")
        case .interrupted:
            Text("Stopped when Filevero quit")
        }
    }

    @ViewBuilder private var actions: some View {
        switch job.status {
        case .waiting, .running:
            Button {
                state.cancel(job)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(FileveroButtonStyle(.quiet, compact: true))
            .help("Cancel")
            .accessibilityLabel("Cancel")
        case .done(let outputs):
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(FileveroButtonStyle(.quiet, compact: true))
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
        case .failed, .cancelled, .interrupted:
            Button {
                state.retry(job)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(FileveroButtonStyle(.quiet, compact: true))
            .help("Retry")
            .accessibilityLabel("Retry")
        }
    }
}

// MARK: - Compatibility Bridge
public typealias JobQueueView = JobExecutionQueueView

