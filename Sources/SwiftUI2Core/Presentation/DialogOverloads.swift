import Foundation

// The alert / confirmationDialog overload family (title as Text, LocalizedStringKey or String;
// presented by a Bool, by optional data, or by an optional item binding; with or without a
// message), all built on `_presentDialog`.

extension View {
    func _presentDialog(title: Text, isPresented: Binding<Bool>, isConfirmation: Bool, actions: @escaping () -> AnyView, message: (() -> AnyView)?) -> some View {
        modifier(_SheetModifier(isPresented: isPresented, onDismiss: nil, content: {
            _DialogContent(title: title, message: message?(), actions: isConfirmation ? AnyView(Group {
                actions()
                Button("Cancel", role: .cancel) {}
            }) : actions(), vertical: isConfirmation)
        }, kind: isConfirmation ? .confirmationDialog : .alert))
    }

    /// Presents while `item` is non-nil; dismissing clears it.
    func _itemBinding<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
    public func alert<A: View, T>(_ title: Text, isPresented: Binding<Bool>, presenting data: T?, @ViewBuilder actions: @escaping (T) -> A) -> some View {
        _presentDialog(title: title, isPresented: isPresented, isConfirmation: false, actions: { AnyView(Group { if let data { actions(data) } }) }, message: nil)
    }
    public func alert<A: View, M: View, T>(_ title: Text, isPresented: Binding<Bool>, presenting data: T?, @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M) -> some View {
        _presentDialog(title: title, isPresented: isPresented, isConfirmation: false, actions: { AnyView(Group { if let data { actions(data) } }) },
                       message: { AnyView(Group { if let data { message(data) } }) })
    }
    public func alert<A: View, T>(_ title: Text, item data: Binding<T?>, @ViewBuilder actions: @escaping (T) -> A) -> some View {
        _presentDialog(title: title, isPresented: _itemBinding(data), isConfirmation: false, actions: { AnyView(Group { if let value = data.wrappedValue { actions(value) } }) }, message: nil)
    }
    public func alert<A: View, M: View, T>(_ title: Text, item data: Binding<T?>, @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M) -> some View {
        _presentDialog(title: title, isPresented: _itemBinding(data), isConfirmation: false, actions: { AnyView(Group { if let value = data.wrappedValue { actions(value) } }) },
                       message: { AnyView(Group { if let value = data.wrappedValue { message(value) } }) })
    }
    public func alert<A: View, T>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, presenting data: T?, @ViewBuilder actions: @escaping (T) -> A) -> some View {
        _presentDialog(title: Text(titleKey), isPresented: isPresented, isConfirmation: false, actions: { AnyView(Group { if let data { actions(data) } }) }, message: nil)
    }
    public func alert<A: View, M: View, T>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, presenting data: T?, @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M) -> some View {
        _presentDialog(title: Text(titleKey), isPresented: isPresented, isConfirmation: false, actions: { AnyView(Group { if let data { actions(data) } }) },
                       message: { AnyView(Group { if let data { message(data) } }) })
    }
    public func alert<A: View, T>(_ titleKey: LocalizedStringKey, item data: Binding<T?>, @ViewBuilder actions: @escaping (T) -> A) -> some View {
        _presentDialog(title: Text(titleKey), isPresented: _itemBinding(data), isConfirmation: false, actions: { AnyView(Group { if let value = data.wrappedValue { actions(value) } }) }, message: nil)
    }
    public func alert<A: View, M: View, T>(_ titleKey: LocalizedStringKey, item data: Binding<T?>, @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M) -> some View {
        _presentDialog(title: Text(titleKey), isPresented: _itemBinding(data), isConfirmation: false, actions: { AnyView(Group { if let value = data.wrappedValue { actions(value) } }) },
                       message: { AnyView(Group { if let value = data.wrappedValue { message(value) } }) })
    }
    public func alert<A: View>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> A) -> some View {
        _presentDialog(title: Text(titleKey), isPresented: isPresented, isConfirmation: false, actions: { AnyView(actions()) }, message: nil)
    }
    public func alert<A: View, M: View>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> A, @ViewBuilder message: @escaping () -> M) -> some View {
        _presentDialog(title: Text(titleKey), isPresented: isPresented, isConfirmation: false, actions: { AnyView(actions()) }, message: { AnyView(message()) })
    }
    @_disfavoredOverload public func alert<S: StringProtocol, A: View, T>(_ title: S, isPresented: Binding<Bool>, presenting data: T?, @ViewBuilder actions: @escaping (T) -> A) -> some View {
        _presentDialog(title: Text(title), isPresented: isPresented, isConfirmation: false, actions: { AnyView(Group { if let data { actions(data) } }) }, message: nil)
    }
    @_disfavoredOverload public func alert<S: StringProtocol, A: View, M: View, T>(_ title: S, isPresented: Binding<Bool>, presenting data: T?, @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M) -> some View {
        _presentDialog(title: Text(title), isPresented: isPresented, isConfirmation: false, actions: { AnyView(Group { if let data { actions(data) } }) },
                       message: { AnyView(Group { if let data { message(data) } }) })
    }
    @_disfavoredOverload public func alert<S: StringProtocol, A: View, T>(_ title: S, item data: Binding<T?>, @ViewBuilder actions: @escaping (T) -> A) -> some View {
        _presentDialog(title: Text(title), isPresented: _itemBinding(data), isConfirmation: false, actions: { AnyView(Group { if let value = data.wrappedValue { actions(value) } }) }, message: nil)
    }
    @_disfavoredOverload public func alert<S: StringProtocol, A: View, M: View, T>(_ title: S, item data: Binding<T?>, @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M) -> some View {
        _presentDialog(title: Text(title), isPresented: _itemBinding(data), isConfirmation: false, actions: { AnyView(Group { if let value = data.wrappedValue { actions(value) } }) },
                       message: { AnyView(Group { if let value = data.wrappedValue { message(value) } }) })
    }
    public func confirmationDialog<A: View, T>(_ title: Text, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, presenting data: T?, @ViewBuilder actions: @escaping (T) -> A) -> some View {
        _presentDialog(title: title, isPresented: isPresented, isConfirmation: true, actions: { AnyView(Group { if let data { actions(data) } }) }, message: nil)
    }
    public func confirmationDialog<A: View, M: View, T>(_ title: Text, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, presenting data: T?, @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M) -> some View {
        _presentDialog(title: title, isPresented: isPresented, isConfirmation: true, actions: { AnyView(Group { if let data { actions(data) } }) },
                       message: { AnyView(Group { if let data { message(data) } }) })
    }
    public func confirmationDialog<A: View, T>(_ title: Text, item data: Binding<T?>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping (T) -> A) -> some View {
        _presentDialog(title: title, isPresented: _itemBinding(data), isConfirmation: true, actions: { AnyView(Group { if let value = data.wrappedValue { actions(value) } }) }, message: nil)
    }
    public func confirmationDialog<A: View, M: View, T>(_ title: Text, item data: Binding<T?>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M) -> some View {
        _presentDialog(title: title, isPresented: _itemBinding(data), isConfirmation: true, actions: { AnyView(Group { if let value = data.wrappedValue { actions(value) } }) },
                       message: { AnyView(Group { if let value = data.wrappedValue { message(value) } }) })
    }
    public func confirmationDialog<A: View>(_ title: Text, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping () -> A) -> some View {
        _presentDialog(title: title, isPresented: isPresented, isConfirmation: true, actions: { AnyView(actions()) }, message: nil)
    }
    public func confirmationDialog<A: View, M: View>(_ title: Text, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping () -> A, @ViewBuilder message: @escaping () -> M) -> some View {
        _presentDialog(title: title, isPresented: isPresented, isConfirmation: true, actions: { AnyView(actions()) }, message: { AnyView(message()) })
    }
    public func confirmationDialog<A: View, T>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, presenting data: T?, @ViewBuilder actions: @escaping (T) -> A) -> some View {
        _presentDialog(title: Text(titleKey), isPresented: isPresented, isConfirmation: true, actions: { AnyView(Group { if let data { actions(data) } }) }, message: nil)
    }
    public func confirmationDialog<A: View, M: View, T>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, presenting data: T?, @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M) -> some View {
        _presentDialog(title: Text(titleKey), isPresented: isPresented, isConfirmation: true, actions: { AnyView(Group { if let data { actions(data) } }) },
                       message: { AnyView(Group { if let data { message(data) } }) })
    }
    public func confirmationDialog<A: View, T>(_ titleKey: LocalizedStringKey, item data: Binding<T?>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping (T) -> A) -> some View {
        _presentDialog(title: Text(titleKey), isPresented: _itemBinding(data), isConfirmation: true, actions: { AnyView(Group { if let value = data.wrappedValue { actions(value) } }) }, message: nil)
    }
    public func confirmationDialog<A: View, M: View, T>(_ titleKey: LocalizedStringKey, item data: Binding<T?>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M) -> some View {
        _presentDialog(title: Text(titleKey), isPresented: _itemBinding(data), isConfirmation: true, actions: { AnyView(Group { if let value = data.wrappedValue { actions(value) } }) },
                       message: { AnyView(Group { if let value = data.wrappedValue { message(value) } }) })
    }
    public func confirmationDialog<A: View>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping () -> A) -> some View {
        _presentDialog(title: Text(titleKey), isPresented: isPresented, isConfirmation: true, actions: { AnyView(actions()) }, message: nil)
    }
    public func confirmationDialog<A: View, M: View>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping () -> A, @ViewBuilder message: @escaping () -> M) -> some View {
        _presentDialog(title: Text(titleKey), isPresented: isPresented, isConfirmation: true, actions: { AnyView(actions()) }, message: { AnyView(message()) })
    }
    @_disfavoredOverload public func confirmationDialog<S: StringProtocol, A: View, T>(_ title: S, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, presenting data: T?, @ViewBuilder actions: @escaping (T) -> A) -> some View {
        _presentDialog(title: Text(title), isPresented: isPresented, isConfirmation: true, actions: { AnyView(Group { if let data { actions(data) } }) }, message: nil)
    }
    @_disfavoredOverload public func confirmationDialog<S: StringProtocol, A: View, M: View, T>(_ title: S, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, presenting data: T?, @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M) -> some View {
        _presentDialog(title: Text(title), isPresented: isPresented, isConfirmation: true, actions: { AnyView(Group { if let data { actions(data) } }) },
                       message: { AnyView(Group { if let data { message(data) } }) })
    }
    @_disfavoredOverload public func confirmationDialog<S: StringProtocol, A: View, T>(_ title: S, item data: Binding<T?>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping (T) -> A) -> some View {
        _presentDialog(title: Text(title), isPresented: _itemBinding(data), isConfirmation: true, actions: { AnyView(Group { if let value = data.wrappedValue { actions(value) } }) }, message: nil)
    }
    @_disfavoredOverload public func confirmationDialog<S: StringProtocol, A: View, M: View, T>(_ title: S, item data: Binding<T?>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M) -> some View {
        _presentDialog(title: Text(title), isPresented: _itemBinding(data), isConfirmation: true, actions: { AnyView(Group { if let value = data.wrappedValue { actions(value) } }) },
                       message: { AnyView(Group { if let value = data.wrappedValue { message(value) } }) })
    }
    @_disfavoredOverload public func confirmationDialog<S: StringProtocol, A: View>(_ title: S, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping () -> A) -> some View {
        _presentDialog(title: Text(title), isPresented: isPresented, isConfirmation: true, actions: { AnyView(actions()) }, message: nil)
    }
    @_disfavoredOverload public func confirmationDialog<S: StringProtocol, A: View, M: View>(_ title: S, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping () -> A, @ViewBuilder message: @escaping () -> M) -> some View {
        _presentDialog(title: Text(title), isPresented: isPresented, isConfirmation: true, actions: { AnyView(actions()) }, message: { AnyView(message()) })
    }
    // Errors: the title is the error's description.

    public func alert<E: LocalizedError, A: View>(isPresented: Binding<Bool>, error: E?, @ViewBuilder actions: @escaping () -> A) -> some View {
        _presentDialog(title: Text(verbatim: error?.errorDescription ?? ""), isPresented: isPresented, isConfirmation: false, actions: { AnyView(actions()) },
                       message: error?.recoverySuggestion.map { suggestion in { AnyView(Text(verbatim: suggestion)) } })
    }

    public func alert<E: LocalizedError, A: View, M: View>(isPresented: Binding<Bool>, error: E?, @ViewBuilder actions: @escaping (E) -> A, @ViewBuilder message: @escaping (E) -> M) -> some View {
        _presentDialog(title: Text(verbatim: error?.errorDescription ?? ""), isPresented: isPresented, isConfirmation: false,
                       actions: { AnyView(Group { if let error { actions(error) } }) }, message: { AnyView(Group { if let error { message(error) } }) })
    }

    public func alert<E: Error, A: View>(error: Binding<E?>, @ViewBuilder actions: @escaping () -> A) -> some View {
        _presentDialog(title: Text(verbatim: error.wrappedValue.map { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription } ?? ""),
                       isPresented: _itemBinding(error), isConfirmation: false, actions: { AnyView(actions()) }, message: nil)
    }

    public func alert<E: Error, A: View, M: View>(error: Binding<E?>, @ViewBuilder actions: @escaping (E) -> A, @ViewBuilder message: @escaping (E) -> M) -> some View {
        _presentDialog(title: Text(verbatim: error.wrappedValue.map { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription } ?? ""),
                       isPresented: _itemBinding(error), isConfirmation: false,
                       actions: { AnyView(Group { if let value = error.wrappedValue { actions(value) } }) },
                       message: { AnyView(Group { if let value = error.wrappedValue { message(value) } }) })
    }

    public func dialogSuppressionToggle(_ titleKey: LocalizedStringKey, isSuppressed: Binding<Bool>) -> some View {
        dialogSuppressionToggle(Text(titleKey), isSuppressed: isSuppressed)
    }
}
