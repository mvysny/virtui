# Specification for adding a scroll bar to Component::List (or List for short)

List needs to have an optional scroll bar. It will consist of these characters:

* `^` for up
* `v` for down
* `#` for the handle (filled track)
* `|` for the slider (empty track)

The visibility of the scroll bar is controlled by a property `List.scrollbar_visibility` with the following values:

* `:gone` - no scrollbar shown (current behavior)
* `:visible` - scrollbar visible at all times
* `:optional` - scrollbar visible only when there are more items than the height of List viewport.

Corner cases:
* When the component is two rows tall and scrollbar needs to be drawn, only draw the arrow keys.
* When the component is one row tall and scrollbar needs to be drawn, only draw the empty track character.

The progress bar will be drawn in `List.paintable_line`; when it is drawn, the space for content
needs to be one character less so that List never draws outside of its rect.

Tests must be implemented too.

Example of how List should look like when it's 10 lines tall, there are 20 items, and the last 10 items are shown:

```
Item 11   ^
Item 12   |
Item 13   |
Item 14   |
Item 15   |
Item 16   #
Item 17   #
Item 18   #
Item 19   #
Item 20   v
```


