import CGraphene
import CGtk
import Gtk
import Pango

@MainActor
enum ChildRowLineLayout {
    static func install(on box: Box) {
        gtk_widget_set_layout_manager(box.widget_ptr, gtk_custom_layout_new(nil, measure, allocate))
    }

    private static let spacing: Int32 = 6
    private static let shortestBadge = 4

    @MainActor
    private struct Parts {
        let title: UnsafeMutablePointer<GtkWidget>
        let badge: UnsafeMutablePointer<GtkWidget>
        let subtitle: UnsafeMutablePointer<GtkWidget>

        init(of box: UnsafeMutablePointer<GtkWidget>?) {
            title = gtk_widget_get_first_child(box)!
            badge = gtk_widget_get_next_sibling(title)!
            subtitle = gtk_widget_get_next_sibling(badge)!
        }

        var hasBadge: Bool {
            gtk_widget_get_visible(badge) != 0
        }

        var hasSubtitle: Bool {
            gtk_widget_get_visible(subtitle) != 0
        }

        var firstLineHeight: Int32 {
            max(ChildRowLineLayout.size(title, GTK_ORIENTATION_VERTICAL).natural, hasBadge ? ChildRowLineLayout.size(badge, GTK_ORIENTATION_VERTICAL).natural : 0)
        }

        var secondLineHeight: Int32 {
            hasSubtitle ? ChildRowLineLayout.size(subtitle, GTK_ORIENTATION_VERTICAL).natural : 0
        }
    }

    private static func size(_ widget: UnsafeMutablePointer<GtkWidget>, _ orientation: GtkOrientation) -> (minimum: Int32, natural: Int32) {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(widget, orientation, -1, &minimum, &natural, nil, nil)
        return (minimum, natural)
    }

    private static func badgeMinimum(_ badge: UnsafeMutablePointer<GtkWidget>) -> Int32 {
        let natural = size(badge, GTK_ORIENTATION_HORIZONTAL).natural
        let text = gtk_label_get_text(UnsafeMutableRawPointer(badge).assumingMemoryBound(to: GtkLabel.self)).map { String(cString: $0) } ?? ""
        guard text.count > shortestBadge + 1 else { return natural }
        let shortened = String(text.prefix(shortestBadge)) + "\u{2026}"
        return natural - textWidth(text, in: badge) + textWidth(shortened, in: badge)
    }

    private static func textWidth(_ text: String, in widget: UnsafeMutablePointer<GtkWidget>) -> Int32 {
        let layout = gtk_widget_create_pango_layout(widget, text)!
        defer { g_object_unref(layout) }
        var width: Int32 = 0
        pango_layout_get_pixel_size(layout, &width, nil)
        return width
    }

    private static func place(_ widget: UnsafeMutablePointer<GtkWidget>, x: Int32, y: Int32, width: Int32, height: Int32) {
        guard gtk_widget_get_visible(widget) != 0 else { return }
        var origin = graphene_point_t(x: Float(x), y: Float(y))
        gtk_widget_allocate(widget, width, height, -1, gsk_transform_translate(nil, &origin))
    }

    private static let measure: GtkCustomMeasureFunc = { box, orientation, _, minimum, natural, _, _ in
        nonisolated(unsafe) let box = box
        nonisolated(unsafe) let minimum = minimum
        nonisolated(unsafe) let natural = natural
        MainActor.assumeIsolated {
            let parts = Parts(of: box)
            guard orientation == GTK_ORIENTATION_HORIZONTAL else {
                let height = parts.firstLineHeight + parts.secondLineHeight
                minimum?.pointee = height
                natural?.pointee = height
                return
            }
            let title = ChildRowLineLayout.size(parts.title, orientation)
            let badge = parts.hasBadge
                ? (minimum: ChildRowLineLayout.badgeMinimum(parts.badge), natural: ChildRowLineLayout.size(parts.badge, orientation).natural)
                : (minimum: Int32(0), natural: Int32(0))
            let gap = parts.hasBadge ? ChildRowLineLayout.spacing : 0
            let subtitle = parts.hasSubtitle ? ChildRowLineLayout.size(parts.subtitle, orientation) : (minimum: Int32(0), natural: Int32(0))
            minimum?.pointee = max(title.minimum + gap + badge.minimum, subtitle.minimum)
            natural?.pointee = max(title.natural + gap + badge.natural, subtitle.natural)
        }
    }

    private static let allocate: GtkCustomAllocateFunc = { box, width, _, _ in
        nonisolated(unsafe) let box = box
        MainActor.assumeIsolated {
            let parts = Parts(of: box)
            let first = parts.firstLineHeight
            let title = ChildRowLineLayout.size(parts.title, GTK_ORIENTATION_HORIZONTAL)
            let titleHeight = ChildRowLineLayout.size(parts.title, GTK_ORIENTATION_VERTICAL).natural
            guard parts.hasBadge else {
                ChildRowLineLayout.place(parts.title, x: 0, y: (first - titleHeight) / 2, width: width, height: titleHeight)
                ChildRowLineLayout.place(parts.subtitle, x: 0, y: first, width: width, height: parts.secondLineHeight)
                return
            }
            let badge = (minimum: ChildRowLineLayout.badgeMinimum(parts.badge), natural: ChildRowLineLayout.size(parts.badge, GTK_ORIENTATION_HORIZONTAL).natural)
            let badgeHeight = ChildRowLineLayout.size(parts.badge, GTK_ORIENTATION_VERTICAL).natural
            let titleWidth = max(title.minimum, min(title.natural, width - ChildRowLineLayout.spacing - badge.minimum))
            let badgeWidth = max(badge.minimum, min(badge.natural, width - titleWidth - ChildRowLineLayout.spacing))
            ChildRowLineLayout.place(parts.title, x: 0, y: (first - titleHeight) / 2, width: titleWidth, height: titleHeight)
            ChildRowLineLayout.place(parts.badge, x: width - badgeWidth, y: (first - badgeHeight) / 2, width: badgeWidth, height: badgeHeight)
            ChildRowLineLayout.place(parts.subtitle, x: 0, y: first, width: width, height: parts.secondLineHeight)
        }
    }
}
