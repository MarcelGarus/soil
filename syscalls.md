| number | mnemonic     | a               | b            | c          | d    | description                          |
| ------ | ------------ | --------------- | ------------ | ---------- | ---- | ------------------------------------ |
| 0      | exit         | status          | -            |            |      | Exits the program.                   |
| 1      | print        | msg.data        | msg.len      |            |      | Prints the message to stdout.        |
| 2      | log          | msg.data        | msg.len      |            |      | Logs the message to stderr.          |
| 3      | create       | filename.data   | filename.len | mode       |      | Creates the file.                    |
| 4      | open_reading | filename.data   | filename.len | flags      | mode | Opens the file.                      |
| 5      | open_writing | filename.data   | filename.len | flags      | mode | Opens the file.                      |
| 6      | read         | file descriptor | buffer.data  | buffer.len |      | Reads from the file into the buffer. |
| 7      | write        | file descriptor | buffer.data  | buffer.len |      | Write to the file from the buffer.   |
| 8      | close        | file descriptor |              |            |      | Close the file.                      |
