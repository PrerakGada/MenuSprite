import SwiftUI
import WorkTracking

private let workViolet = Color(red: 0.43, green: 0.34, blue: 0.78)

/// A persistent report window: navigation on the left, comparable numbers in the middle,
/// and source evidence/billing controls in a separate inspector. No idle animation.
struct WorkBoard: View {
    @ObservedObject var store: WorkStore
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 208)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                if let error = store.error { message(error, error: true) }
                if let notice = store.notice { message(notice, error: false) }
                if store.showAI { aiAccounting }
                else if store.showSource { sourceDetails }
                else { report }
                footer
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(workViolet)
        .environment(\.timeZone, WorkReport.calendar.timeZone)
        .environment(\.calendar, WorkReport.calendar)
        .sheet(isPresented: $store.showManual) { WorkManualSheet(store: store) }
        .sheet(item: $store.billingProject) { WorkBillingSheet(store: store, project: $0) }
        .frame(minWidth: 990, minHeight: 650)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.checkmark").font(.system(size: 25)).foregroundStyle(workViolet)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Work & clients").font(.system(size: 16, weight: .semibold))
                    Text("MenuSprite").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 18).padding(.top, 26).padding(.bottom, 30)
            nav("All clients", icon: "tray.full", active: store.client == nil && !store.showAI && !store.showSource) {
                navigate(nil)
            }
            nav("Needs a client", icon: "person.crop.circle.badge.questionmark", active: store.client == "" && !store.showAI && !store.showSource,
                trailing: store.unassigned > 0 ? WorkReport.hours(store.unassigned) : nil) { navigate("") }
            Text("Clients in this period").font(.caption).foregroundStyle(.secondary).padding(.leading, 19).padding(.top, 26).padding(.bottom, 9)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.clients, id: \.self) { client in
                        nav(client, icon: "building.2", active: store.client == client && !store.showAI && !store.showSource) { navigate(client) }
                    }
                    if store.clients.isEmpty { Text("Assigned clients appear here.").font(.caption).foregroundStyle(.secondary).padding(18) }
                }
            }
            Divider().padding(.horizontal, 16)
            nav("AI accounting", icon: "sparkles", active: store.showAI) { store.showAI = true; store.showSource = false }
            nav("Data & coverage", icon: "externaldrive", active: store.showSource) { store.showSource = true; store.showAI = false }
            VStack(alignment: .leading, spacing: 6) {
                Label("Stored on this Mac", systemImage: "lock.shield").font(.caption)
                Text("Your time, clients and rates stay local.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(19)
        }.background(workViolet.opacity(0.035))
    }
    private func navigate(_ client: String?) {
        store.client = client; store.selectedProject = nil; store.showSource = false; store.showAI = false
    }
    private func nav(_ title: String, icon: String, active: Bool, trailing: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 17).foregroundStyle(active ? workViolet : .secondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                if let trailing { Text(trailing).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary) }
            }.font(.system(size: 12, weight: active ? .semibold : .regular))
                .padding(.horizontal, 11).padding(.vertical, 11)
                .background(active ? workViolet.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 8)
    }
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.showAI ? "AI accounting" : store.showSource ? "Data & coverage" : store.client.map { $0.isEmpty ? "Needs a client" : $0 } ?? "Work report")
                        .font(.system(size: 25, weight: .semibold))
                    Text(store.showAI ? "Understand what each project costs in AI." : store.showSource ? "Know what is included before you use the numbers." : "Hours and billing evidence, by project.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.showManual = true } label: { Label("Add time", systemImage: "plus") }
                    .accessibilityIdentifier("work-add-time")
                Menu {
                    Button("Project summary…") { store.export(detail: false) }
                    Button("Time entries…") { store.export(detail: true) }
                } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    .disabled(store.filtered.isEmpty || store.showAI || store.showSource)
                    .accessibilityIdentifier("work-export")
            }
            if !store.showAI && !store.showSource {
                HStack(spacing: 14) {
                    Picker("Period", selection: $store.period) { ForEach(WorkPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .labelsHidden().foregroundStyle(.primary).frame(width: 140).accessibilityIdentifier("work-period")
                    if store.period == .custom {
                        DatePicker("From", selection: $store.from, displayedComponents: .date).labelsHidden().frame(width: 105)
                        Text("to").foregroundStyle(.secondary)
                        DatePicker("Through", selection: $store.through, in: store.from..., displayedComponents: .date).labelsHidden().frame(width: 105)
                    } else {
                        Text("\(WorkStore.day(store.range.start))  –  \(WorkStore.day(min(Date(), store.range.end.addingTimeInterval(-1))))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text("IST").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    TextField("Find a project", text: $store.search).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                        .accessibilityIdentifier("work-search")
                }
            }
        }.padding(.horizontal, 26).padding(.vertical, 22)
    }
    private var report: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 30) {
                summary("Recorded time", value: WorkReport.hours(store.tracked), detail: "Terminal activity + manual entries")
                Divider().frame(height: 64)
                summary("Marked billable", value: WorkReport.hours(store.billable), detail: "Only projects you mark billable")
                Divider().frame(height: 64)
                summary("Billing estimate", value: store.amountSummary, detail: store.unrated > 0 ? "\(store.unrated) billable project(s) still need a rate" : "Hours × your client rates; excludes AI")
                Spacer(minLength: 0)
            }.padding(.horizontal, 26).padding(.vertical, 24)
            if !store.filtered.isEmpty { activityChart }
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Projects").font(.headline)
                        Text("\(store.filtered.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Select a row to review").font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 24).padding(.vertical, 15)
                    if store.filtered.isEmpty {
                        ContentUnavailableView(store.loading ? "Reading your history" : "No time in this view", systemImage: store.loading ? "clock" : "calendar",
                                               description: Text(store.loading ? "Loading recorded project intervals from paneclock." : "Try All history, clear your search, or add time for a call or meeting."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { projectTable }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let selected = store.selected {
                    Divider()
                    WorkInspector(store: store, project: selected).id(selected.id).frame(width: 305)
                }
            }
        }.frame(maxHeight: .infinity)
    }
    private func summary(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(2).minimumScaleFactor(0.8)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var activityChart: some View {
        let daily = WorkReport.daily(store.filtered)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recorded activity").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.client == "" { Text("Assign clients in project details").font(.caption).foregroundStyle(workViolet) }
            }
            WorkActivityChart(days: daily, range: store.range).frame(height: 90)
        }.padding(.horizontal, 27).padding(.bottom, 22)
    }
    private var projectTable: some View {
        Table(store.filtered, selection: $store.selectedProject) {
            TableColumn("Project") { project in
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).fontWeight(.medium).lineLimit(1).help(project.name)
                    Text(project.client.isEmpty ? "Needs a client" : project.client).font(.caption).foregroundStyle(project.client.isEmpty ? .orange : .secondary)
                }.padding(.vertical, 6)
            }.width(min: 140, ideal: 230)
            TableColumn("Time") { Text(WorkReport.hours($0.seconds)).monospacedDigit() }.width(78)
            TableColumn("Billing") { project in
                VStack(alignment: .trailing, spacing: 4) {
                    Text(project.billable ? (project.amount.flatMap { amount in project.rate.map { WorkReport.money(amount, currency: $0.currency) } } ?? "Rate not set") : "Non-billable")
                        .foregroundStyle(project.billable ? .primary : .secondary).monospacedDigit()
                    if project.manualSeconds > 0 { Text("Includes manual time").font(.caption2).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .trailing)
            }.width(min: 110, ideal: 145)
        }.tableStyle(.inset(alternatesRowBackgrounds: true)).accessibilityIdentifier("work-project-table")
    }
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "externaldrive").foregroundStyle(.secondary)
                Text(store.lastRecorded.map { "paneclock last recorded \(Self.timestamp($0)) IST" } ?? "paneclock has not supplied any history")
                    .lineLimit(1).help("This is the last interval in the database, not proof that the collector is currently running.")
                Spacer()
                if store.loading { ProgressView().controlSize(.mini) }
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command).accessibilityIdentifier("work-refresh")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 11)
        }
    }
    private func message(_ text: String, error: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: error ? "exclamationmark.triangle" : "checkmark.circle")
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if !error && store.removedEntry != nil { Button("Undo") { store.undoRemove() } }
            Button { if error { store.error = nil } else { store.notice = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss message")
        }.font(.callout).padding(12).background(error ? Color.orange.opacity(0.1) : workViolet.opacity(0.08))
    }
    private var sourceDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("paneclock history", systemImage: "externaldrive").font(.title2.weight(.medium))
                Text(store.preferences.sourcePath).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Text("\(store.source.count.formatted()) intervals available").font(.headline)
                    Spacer()
                    Button("Choose database…") { store.chooseSource() }
                }
                Divider()
                coverage("Included", text: "Active time recorded by paneclock in terminal panes, plus the calls, meetings and other work you add by hand.", symbol: "checkmark.circle")
                coverage("Not a complete working day", text: "Browser work, other apps and unrecorded meetings are not in the paneclock history. Missing time is never distributed across clients.", symbol: "clock.badge.questionmark")
                coverage("Dates use India Standard Time", text: "Reports follow calendar days in Asia/Kolkata. An interval crossing a date boundary contributes a proportional share of its active time to each side.", symbol: "calendar")
                coverage("Billing is your decision", text: "Projects start non-billable. Client assignments and hourly rates apply to all dates in this report, including history. They do not create invoices or change paneclock’s source rules.", symbol: "indianrupeesign.circle")
                coverage("Existing collector", text: "paneclock continues recording. MenuSprite reads its database every 30 seconds while this window is open. The native collector migration has not been implemented.", symbol: "arrow.triangle.2.circlepath")
                coverage("Separate local settings", text: "Client overrides, rates and manual entries are saved in MenuSprite’s Application Support folder. The tracking database is opened read-only; its history is not imported or overwritten.", symbol: "lock.shield")
            }.padding(30).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var aiAccounting: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("Project usage is not connected yet", systemImage: "sparkles").font(.title2.weight(.medium))
                Text("The Claude and Codex sprites show account limits. They do not measure how much a client’s project consumed. No AI cost is included in this report or its billing estimates.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                coverage("Tokens", text: "The consumption recorded for each project. Per-project session-log accounting is not implemented yet.", symbol: "number")
                coverage("API price equivalent", text: "What the same usage would cost at API list prices. This is a comparison, not money spent on a subscription.", symbol: "equal.circle")
                coverage("Share of the real bill", text: "Your actual plan cost allocated by token share. This needs both verified project usage and the monthly price you enter.", symbol: "chart.pie")
                Text("These values will need separate export choices once project usage is available.").font(.callout).foregroundStyle(.secondary)
            }.padding(30).frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func coverage(_ title: String, text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: symbol).font(.title3).foregroundStyle(workViolet).frame(width: 24)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter(); f.timeZone = WorkReport.calendar.timeZone; f.dateFormat = "d MMM, HH:mm"
        return f.string(from: date)
    }
}

private struct WorkInspector: View {
    @ObservedObject var store: WorkStore
    let project: WorkProject
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Text(project.name).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
                    Spacer()
                    Button { store.selectedProject = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close project details")
                }
                HStack {
                    Text(WorkReport.hours(project.seconds)).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                    Spacer()
                    Text("\(project.entries.count) intervals").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text(project.client.isEmpty ? "No client assigned" : project.client).font(.headline)
                    Text(project.billable ? "Marked billable" : "Non-billable").foregroundStyle(.secondary)
                    if let rate = project.rate { Text("\(WorkReport.money(rate.hourly, currency: rate.currency)) / hour").monospacedDigit() }
                    else { Text("Hourly rate not set").foregroundStyle(.secondary) }
                    Button("Edit client & billing…") { store.billingProject = project }.accessibilityIdentifier("work-edit-billing")
                }.font(.callout)
                Divider()
                HStack { Text("Recent time entries").font(.headline); Spacer(); Button { store.showManual = true } label: { Image(systemName: "plus") }.help("Add manual time") }
                ForEach(Array(project.entries.prefix(40))) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(WorkBoard.timestamp(entry.start)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(WorkReport.hours(entry.seconds)).font(.callout).monospacedDigit()
                        }
                        Text(entry.manual ? entry.note : (entry.path.isEmpty ? "Path not recorded" : entry.path))
                            .font(.caption).lineLimit(2).textSelection(.enabled).help(entry.manual ? entry.note : entry.path)
                        HStack {
                            Text(entry.manual ? "Manual entry" : "Terminal • \(entry.attribution)").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            if entry.manual { Button("Remove") { store.removeManual(entry.id) }.font(.caption2).buttonStyle(.borderless) }
                        }
                    }.padding(.vertical, 3)
                    Divider()
                }
                if project.entries.count > 40 { Text("Showing the latest 40. Export time entries for the full record.").font(.caption).foregroundStyle(.secondary) }
            }.padding(20)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
}

private struct WorkBillingSheet: View {
    @ObservedObject var store: WorkStore
    let project: WorkProject
    @Environment(\.dismiss) private var dismiss
    @State private var client = ""
    @State private var billable = false
    @State private var hourly = ""
    @State private var currency = "INR"
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Client & billing").font(.title2.weight(.semibold))
            Text(project.name).foregroundStyle(.secondary)
            Form {
                TextField("Client", text: $client)
                if !store.clients.isEmpty {
                    Picker("Use existing client", selection: $client) {
                        Text("Choose…").tag(client)
                        ForEach(store.clients.filter { $0 != client }, id: \.self) { Text($0).tag($0) }
                    }
                }
                Toggle("Mark this project billable", isOn: $billable)
                TextField("Hourly rate", text: $hourly, prompt: Text("Not set"))
                Picker("Currency", selection: $currency) { ForEach(["INR", "USD", "EUR", "GBP", "AED", "CAD", "AUD"], id: \.self) { Text($0).tag($0) } }
            }.textFieldStyle(.roundedBorder)
            Text("The rate is shared by all projects assigned to this client. Changes apply to the entire report history. Leave the rate blank to keep it unset.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save changes") {
                    if store.configure(project, client: client, billable: billable, hourly: hourly, currency: currency) { dismiss() }
                    else { error = store.error }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 450).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { client = project.client; billable = project.billable; hourly = project.rate.map { "\($0.hourly)" } ?? ""; currency = project.rate?.currency ?? "INR" }
            .onChange(of: client) { _, next in hourly = store.preferences.rates[next].map { "\($0.hourly)" } ?? ""; currency = store.preferences.rates[next]?.currency ?? currency }
    }
}

private struct WorkManualSheet: View {
    @ObservedObject var store: WorkStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = ""
    @State private var project = ""
    @State private var client = ""
    @State private var start = Date().addingTimeInterval(-1800)
    @State private var end = Date()
    @State private var note = ""
    @State private var allowOverlap = false
    @State private var error: String?
    private var entry: WorkInterval {
        let selected = store.projects.first { $0.id == selectedID }
        return WorkInterval(start: start, end: end, seconds: end.timeIntervalSince(start),
                            project: selected?.name ?? project.trimmingCharacters(in: .whitespacesAndNewlines),
                            client: selected?.originalClient ?? client.trimmingCharacters(in: .whitespacesAndNewlines), note: note, manual: true)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add time").font(.title2.weight(.semibold))
            Text("Record a meeting, call or work outside the terminal.").foregroundStyle(.secondary)
            Form {
                Picker("Project", selection: $selectedID) {
                    Text("New project").tag("")
                    ForEach(store.projects) { Text("\($0.name) — \($0.client.isEmpty ? "No client" : $0.client)").tag($0.id) }
                }
                if selectedID.isEmpty {
                    TextField("Project name", text: $project)
                    TextField("Client", text: $client, prompt: Text("Can be assigned later"))
                }
                DatePicker("Start (IST)", selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                DatePicker("End (IST)", selection: $end, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                TextField("Description", text: $note, prompt: Text("e.g. Accounts review call"), axis: .vertical).lineLimit(2...4)
            }.textFieldStyle(.roundedBorder)
            Text("Duration: \(WorkReport.hours(max(0, end.timeIntervalSince(start))))").font(.headline).monospacedDigit()
            if start < end && store.overlaps(entry) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This overlaps an existing interval. Adding it may count the same time twice.").font(.callout).foregroundStyle(.orange)
                    Toggle("I reviewed the overlap; include this time", isOn: $allowOverlap).font(.callout)
                }
            }
            Text("Manual time follows the project’s billing setting. A new project starts non-billable.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add time") {
                    if store.addManual(entry, allowOverlap: allowOverlap) { dismiss() } else { error = store.error }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 500).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { selectedID = store.selectedProject ?? "" }
            .onChange(of: start) { _, _ in allowOverlap = false }
            .onChange(of: end) { _, _ in allowOverlap = false }
            .environment(\.timeZone, WorkReport.calendar.timeZone)
    }
}
