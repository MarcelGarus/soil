| number | mnemonic      | a               | b            | c             | d    |
| ------ | ------------- | --------------- | ------------ | ------------- | ---- |
| 0      | exit          | status          |              |               |      |
| 1      | print         | msg.data        | msg.len      |               |      |
| 2      | log           | msg.data        | msg.len      |               |      |
| 3      | create        | filename.data   | filename.len | mode          |      |
| 4      | open_reading  | filename.data   | filename.len | flags         | mode |
| 5      | open_writing  | filename.data   | filename.len | flags         | mode |
| 6      | read          | file descriptor | buffer.data  | buffer.len    |      |
| 7      | write         | file descriptor | buffer.data  | buffer.len    |      |
| 8      | close         | file descriptor |              |               |      |
| 9      | argc          |                 |              |               |      |
| 10     | arg           | arg index       | buffer.data  | buffer.len    |      |
| 11     | read_input    | buffer.data     | buffer.len   |               |      |
| 12     | execute       | binary.data     | binary.len   |               |      |
| 13     | ui_dimensions |                 |              |               |      |
| 14     | ui_render     | buffer.data     | buffer.width | buffer.height |      |

- **exit**: Exits the program. This is guaranteed to never return.
- **print**: Writes the message to stdout.
- **log**: Writes the message to stderr.
- **create**: Creates the file. Sets `a` to a file descriptor or zero if it didn't work.
- **open_reading**: Opens the file for reading. Sets `a` to a file descriptor or zero if it didn't work.
- **open_writing**: Opens the file for writing. Sets `a` to a file descriptor or zero if it didn't work.
- **read**: Reads from the file descriptor into the buffer, at most buffer.len. Sets `a` to the amount of bytes that were read.
- **write**: Writes from the buffer to the file descriptor, at most buffer.len. Sets `a` to the amount of bytes that were written.
- **close**: Closes the file descriptor. Sets `a` to one if it worked or zero if it didn't work.
- **argc**: Sets `a` to the number of arguments given to the program, including the program name itself.
- **arg**: Fills the buffer with the indexth argument, at most buffer.len. Sets `a` to the amount of bytes that were written.
- **read_input**: Reads from stdin into the buffer, at most buffer.len. Sets `a` to the amount of bytes that were read.
- **execute**: Loads the given binary into the current VM, replacing the current execution.
- **ui_dimensions:** Loads the UI width into `a`, its height into `b`.
- **ui_render:** Renders the buffer as a UI. Outer dimension is height, inner dimensions is width, each pixel is three bytes (RGB).
