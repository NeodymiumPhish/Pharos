import AppKit

extension NSLayoutConstraint {
    /// Switch a view between alternative layouts: deactivate `off`, then
    /// activate `on`, in that order. Activating first leaves both sets active
    /// for a moment; two required constraints then cannot both hold, so
    /// AppKit logs "Conflicting constraints detected" and breaks a third one
    /// to recover (Auto Layout Guide, "Unsatisfiable Layouts").
    static func swap(activate on: [NSLayoutConstraint], deactivate off: [NSLayoutConstraint]) {
        NSLayoutConstraint.deactivate(off)
        NSLayoutConstraint.activate(on)
    }
}
