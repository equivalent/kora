# Kora - Personal Knowledge Organizer

A command-line Ruby application for organizing personal knowledge with full-text search capabilities.

## Features

- Create and organize items with tags
- Full-text search with partial word matching and diacritic-insensitive search across item names, descriptions, and tags
- Automatic folder creation for file storage
- Tag management with case-insensitive uniqueness
- SQLite database with efficient LIKE-based search

## Installation

1. Install Ruby 3.4+
2. Install the sqlite3 gem: `gem install sqlite3`
3. Run the application: `ruby main.rb` or `./main.rb`

Note: Only the sqlite3 gem is required. The application uses vanilla Ruby 3.4 syntax.

## Database Schema

### Items
- id: integer (primary key)
- name: string
- description: text
- path: string (relative path to storage folder)
- created_at: date
- updated_at: datetime

### Tags
- id: integer (primary key)
- name: string (case-insensitive unique)

### Taggings
- id: integer (primary key)
- tag_id: integer (foreign key to tags)
- item_id: integer (foreign key to items)

## Usage

The application provides a simple numbered menu interface:

### Main Menu
1. **Search Item** - Search for items by keyword (supports diacritic-insensitive search)
2. **Find Item by Tag** - Browse and filter tags to find items by tag
3. **Create New Item** - Add a new item with tags and description
0. **Exit** - Quit the application

### Creating Items
- Enter item name
- Specify date (YYYY-MM-DD format, defaults to today)
- Select/add tags (press 0 to create new tags)
- Optionally add a multiline description
- A storage folder is automatically created: `./storage/YYYY-MM-DD_sanitized-name/`

### Finding Items by Search
- **Interactive filtering**: Shows 50 most recent items initially
- **Type to filter**: Start typing to instantly filter items in real-time
- **Diacritic-insensitive search**: Searching for "ziadost" will find "Žiadosť"
- **Press Enter to clear**: Return to showing recent items
- **Type 0 to go back**: Return to main menu
- Results show: date | name | [tags]
- Select item by number for operations:
  - Open folder in file manager
  - Edit item details
  - Delete item (with confirmation)

### Finding Items by Tag
- Browse all tags alphabetically
- **Type to filter**: Start typing to narrow down the tag list
- **Diacritic-insensitive filtering**: "med" finds "MEDOVKA"
- **Type 0 to go back**: Return to main menu at any time
- Select tag by number to see all items with that tag
- From item list, select item by number for operations or 0 to go back

## File Storage

Each item gets its own folder under `./storage/` with the naming pattern:
`YYYY-MM-DD_first-25-chars-of-sanitized-name/`

Files can be added to these folders through the system's file manager.
