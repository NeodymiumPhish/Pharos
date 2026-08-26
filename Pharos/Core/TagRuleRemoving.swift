// MARK: - TagRuleRemoving

/// One store capability on its own: remove tag rules by id.
///
/// It was extracted for the removal sheet the Tag Manager replaced, whose
/// standalone harness had to compile a view controller WITHOUT the store.
/// That sheet is gone and the Tag Manager commits through
/// `TagManagerCommitting` instead, so nothing takes this protocol as a
/// dependency today — `TagStore` conforms and `TagStore.apply` calls its own
/// `removeTuples(ids:)` directly.
///
/// It stays in its own file, depending on nothing, because
/// `scripts/test-tag-store.sh` compiles the STORE and therefore needs the
/// protocol its conformance names, without dragging in an AppKit view
/// controller to get it. Declaring it inside a sheet broke that suite once
/// already, and the break went unnoticed because that suite needs a Keychain
/// prompt and so is never run headlessly.
protocol TagRuleRemoving {
    func removeTuples(ids: [String]) throws
}
