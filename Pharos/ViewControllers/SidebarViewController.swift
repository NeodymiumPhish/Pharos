import AppKit

class SidebarViewController: NSViewController {

    private let segmentedControl = NSSegmentedControl()
    private let navigatorContainer = NSView()
    private let libraryContainer = NSView()

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.view = container

        // Top segmented control: Navigator | Library
        segmentedControl.segmentCount = 2
        segmentedControl.setLabel("Navigator", forSegment: 0)
        segmentedControl.setLabel("Library", forSegment: 1)
        segmentedControl.segmentStyle = .texturedSquare
        segmentedControl.selectedSegment = 0
        segmentedControl.target = self
        segmentedControl.action = #selector(topSegmentChanged(_:))
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false

        navigatorContainer.translatesAutoresizingMaskIntoConstraints = false
        libraryContainer.translatesAutoresizingMaskIntoConstraints = false
        libraryContainer.isHidden = true

        container.addSubview(segmentedControl)
        container.addSubview(navigatorContainer)
        container.addSubview(libraryContainer)

        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            segmentedControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            segmentedControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            navigatorContainer.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
            navigatorContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            navigatorContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            navigatorContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            libraryContainer.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
            libraryContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            libraryContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            libraryContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Add placeholder labels
        addPlaceholder(to: navigatorContainer, text: "Schema Browser")
        addPlaceholder(to: libraryContainer, text: "Saved Queries / History")
    }

    @objc private func topSegmentChanged(_ sender: NSSegmentedControl) {
        let isNavigator = sender.selectedSegment == 0
        navigatorContainer.isHidden = !isNavigator
        libraryContainer.isHidden = isNavigator
    }

    private func addPlaceholder(to container: NSView, text: String) {
        let label = NSTextField(labelWithString: text)
        label.textColor = .tertiaryLabelColor
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }
}
