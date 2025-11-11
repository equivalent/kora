#!/usr/bin/env ruby

require 'sqlite3'
require 'date'
require 'fileutils'
require 'set'

# Unicode normalization for diacritic-insensitive search
class String
  def normalize_diacritics
    # Convert to decomposed form (NFD) which separates base characters from diacritics
    decomposed = unicode_normalize(:nfd)
    # Remove diacritical marks (combining characters in Unicode category "Mark")
    decomposed.gsub(/\p{M}/, '').unicode_normalize(:nfc)
  end
end

# Database setup
DB_PATH = 'kora.db'

class Database
  def self.connect
    @db ||= SQLite3::Database.new(DB_PATH)
    @db.results_as_hash = true
    @db
  end

  def self.init
    db = connect

    # Create tables
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        description TEXT,
        path TEXT NOT NULL,
        created_at DATE NOT NULL,
        updated_at DATETIME NOT NULL
      );
    SQL

    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS tags (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE COLLATE NOCASE
      );
    SQL

    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS taggings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        tag_id INTEGER NOT NULL,
        item_id INTEGER NOT NULL,
        FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE,
        FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE,
        UNIQUE(tag_id, item_id)
      );
    SQL

    # Create storage directory
    FileUtils.mkdir_p('storage')
  end
end

class Item
  attr_accessor :id, :name, :description, :path, :created_at, :updated_at

  def initialize(attributes = {})
    @id = attributes['id'] || attributes[:id]
    @name = attributes['name'] || attributes[:name]
    @description = attributes['description'] || attributes[:description]
    @path = attributes['path'] || attributes[:path]
    @created_at = attributes['created_at'] || attributes[:created_at]
    @updated_at = attributes['updated_at'] || attributes[:updated_at]
  end

  def self.all
    db = Database.connect
    db.execute("SELECT * FROM items ORDER BY created_at DESC").map { |row| Item.new(row) }
  end

  def self.find(id)
    db = Database.connect
    row = db.get_first_row("SELECT * FROM items WHERE id = ?", id)
    row ? Item.new(row) : nil
  end

  def self.search(keyword)
    return all if keyword.strip.empty?

    db = Database.connect
    original_pattern = "%#{keyword}%"
    normalized_keyword = keyword.normalize_diacritics
    normalized_pattern = "%#{normalized_keyword}%"

    # Get all items and filter in Ruby since SQLite doesn't have good Unicode normalization
    all_items = db.execute(<<-SQL).map { |row| Item.new(row) }
      SELECT i.*, GROUP_CONCAT(t.name) as tag_names
      FROM items i
      LEFT JOIN taggings tg ON i.id = tg.item_id
      LEFT JOIN tags t ON tg.tag_id = t.id
      GROUP BY i.id
      ORDER BY i.created_at DESC
    SQL

    # Filter items that match either the original keyword or normalized keyword
    matching_items = all_items.select do |item|
      name_match = item.name&.downcase&.include?(keyword.downcase) ||
                   item.name&.normalize_diacritics&.downcase&.include?(normalized_keyword.downcase)
      desc_match = item.description&.downcase&.include?(keyword.downcase) ||
                   item.description&.normalize_diacritics&.downcase&.include?(normalized_keyword.downcase)
      tag_match = item.tag_names.any? do |tag|
        tag.downcase.include?(keyword.downcase) ||
        tag.normalize_diacritics.downcase.include?(normalized_keyword.downcase)
      end

      name_match || desc_match || tag_match
    end

    matching_items
  end

  def tags
    return @tags if @tags

    db = Database.connect
    query = <<-SQL
      SELECT t.* FROM tags t
      JOIN taggings tg ON t.id = tg.tag_id
      WHERE tg.item_id = ?
      ORDER BY t.name
    SQL
    @tags = db.execute(query, [@id]).map { |row| Tag.new(row) }
  end

  def tag_names
    tags.map(&:name)
  end

  def save
    db = Database.connect

    if @id
      # Update
      params = [@name, @description, @path, Time.now.strftime('%Y-%m-%d %H:%M:%S'), @id]
      db.execute("UPDATE items SET name = ?, description = ?, path = ?, updated_at = ? WHERE id = ?", params)
    else
      # Insert
      params = [@name, @description, @path, @created_at, Time.now.strftime('%Y-%m-%d %H:%M:%S')]
      db.execute("INSERT INTO items (name, description, path, created_at, updated_at) VALUES (?, ?, ?, ?, ?)", params)
      @id = db.last_insert_row_id
    end
  end

  def destroy
    return unless @id

    db = Database.connect
    db.execute("DELETE FROM taggings WHERE item_id = ?", [@id])
    db.execute("DELETE FROM items WHERE id = ?", [@id])

    # Remove folder
    FileUtils.rm_rf(@path) if Dir.exist?(@path)
  end

  def update_tags(tag_ids)
    return unless @id

    db = Database.connect
    db.execute("DELETE FROM taggings WHERE item_id = ?", [@id])

    tag_ids.each do |tag_id|
      db.execute("INSERT INTO taggings (tag_id, item_id) VALUES (?, ?)", [tag_id, @id])
    end
  end

  def create_folder
    sanitized_name = @name.downcase.gsub(/[^a-z0-9\s]/, '').gsub(/\s+/, '-')[0..24]
    date_str = Date.parse(@created_at).strftime('%Y-%m-%d')
    folder_name = "#{date_str}_#{sanitized_name}"

    @path = File.join('storage', folder_name)
    FileUtils.mkdir_p(@path)
  end

  def open_folder
    system('open', @path) if Dir.exist?(@path)
  end
end

class Tag
  attr_accessor :id, :name

  def initialize(attributes = {})
    @id = attributes['id'] || attributes[:id]
    @name = attributes['name'] || attributes[:name]
  end

  def self.all
    db = Database.connect
    db.execute("SELECT * FROM tags ORDER BY name COLLATE NOCASE").map { |row| Tag.new(row) }
  end

  def self.find_or_create_by_name(name)
    db = Database.connect
    normalized_name = name.upcase

    existing = db.get_first_row("SELECT * FROM tags WHERE name = ? COLLATE NOCASE", normalized_name)
    return Tag.new(existing) if existing

    db.execute("INSERT INTO tags (name) VALUES (?)", [normalized_name])
    Tag.new('id' => db.last_insert_row_id, 'name' => normalized_name)
  end

  def save
    Tag.find_or_create_by_name(@name)
  end
end

class CLI
  def initialize
    Database.init
    @running = true
  end

  def run
    while @running
      show_main_menu
      choice = gets.chomp.to_i

      case choice
      when 1
        search_item
      when 2
        find_item_by_tag
      when 3
        create_item
      when 0
        @running = false
      else
        puts "Invalid option. Please try again."
      end
    end
  end

  private

  def show_main_menu
    puts "\nKORA - file archive"
    puts "1. Search Item"
    puts "2. Find Item by Tag"
    puts "3. Create New Item"
    puts "0. Exit"
    print "Choose an option: "
  end

  def search_item
    puts "\n=== Search Items ==="
    puts "Showing 50 most recent items (type to filter, press number to select, 0 to go back):"

    # Get all items for filtering
    all_items = Item.all

    filter_text = ""
    loop do
      # Filter items based on current filter_text
      filtered_items = if filter_text.empty?
        # Show 50 most recent items initially
        all_items.first(50)
      else
        # Filter by search term (supports partial and diacritic-insensitive matching)
        normalized_filter = filter_text.normalize_diacritics.downcase
        all_items.select do |item|
          name_match = item.name.downcase.include?(filter_text.downcase) ||
                       item.name.normalize_diacritics.downcase.include?(normalized_filter)
          desc_match = item.description&.downcase&.include?(filter_text.downcase) ||
                       item.description&.normalize_diacritics&.downcase&.include?(normalized_filter)
          tag_match = item.tag_names.any? do |tag|
            tag.downcase.include?(filter_text.downcase) ||
            tag.normalize_diacritics.downcase.include?(normalized_filter)
          end

          name_match || desc_match || tag_match
        end.first(50) # Limit to 50 results
      end

      if filtered_items.empty?
        puts "\nNo items match '#{filter_text}'. Keep typing or press Enter to clear filter."
      else
        puts "\n#{filter_text.empty? ? 'Recent Items' : "Filtered Items (filter: '#{filter_text}')"}:"
        filtered_items.each_with_index do |item, index|
          tags_str = item.tag_names.any? ? " [#{item.tag_names.join(', ')}]" : ""
          puts "#{index + 1}. #{item.created_at} | #{item.name}#{tags_str}"
        end
      end

      print "\nType to filter or select (number/0 to go back): "
      input = gets.chomp

      if input == '0'
        break
      elsif input.empty?
        filter_text = ""  # Clear filter to show recent items again
      elsif input.match?(/^\d+$/)
        choice = input.to_i
        if choice.between?(1, filtered_items.length)
          selected_item = filtered_items[choice - 1]
          show_item_menu(selected_item)
          break  # Return to main menu after showing item
        else
          puts "Invalid number. Please select a valid item number."
        end
      else
        filter_text = input  # Update filter text
      end
    end
  end

  def find_item_by_tag
    all_tags = Tag.all.sort_by { |tag| tag.name.normalize_diacritics.downcase }

    if all_tags.empty?
      puts "No tags found in the database."
      return
    end

    puts "\n=== Find Item by Tag ==="
    puts "Available Tags (type to filter, press number to select, 0 to go back):"

    filter_text = ""
    loop do
      # Filter tags based on current filter_text
      filtered_tags = if filter_text.empty?
        all_tags
      else
        normalized_filter = filter_text.normalize_diacritics.downcase
        all_tags.select do |tag|
          tag.name.downcase.include?(filter_text.downcase) ||
          tag.name.normalize_diacritics.downcase.include?(normalized_filter)
        end
      end

      if filtered_tags.empty?
        puts "\nNo tags match '#{filter_text}'. Keep typing or press Enter to clear filter."
      else
        puts "\nFiltered Tags#{filter_text.empty? ? '' : " (filter: '#{filter_text}')"}:"
        filtered_tags.each_with_index do |tag, index|
          puts "#{index + 1}. #{tag.name}"
        end
      end

      print "\nType to filter or select (number/0 to go back): "
      input = gets.chomp

      if input == '0'
        break
      elsif input.empty?
        filter_text = ""  # Clear filter
      elsif input.match?(/^\d+$/)
        choice = input.to_i
        if choice.between?(1, filtered_tags.length)
          selected_tag = filtered_tags[choice - 1]
          show_items_for_tag(selected_tag)
          break  # Return to main menu after showing items
        else
          puts "Invalid number. Please select a valid tag number."
        end
      else
        filter_text = input  # Update filter text
      end
    end
  end

  def show_items_for_tag(tag)
    # Find items that have this tag
    db = Database.connect
    query = <<-SQL
      SELECT i.*, GROUP_CONCAT(t.name) as tag_names
      FROM items i
      JOIN taggings tg ON i.id = tg.item_id
      JOIN tags t ON tg.tag_id = t.id
      WHERE tg.tag_id = ?
      GROUP BY i.id
      ORDER BY i.created_at DESC
    SQL

    items = db.execute(query, [tag.id]).map { |row| Item.new(row) }

    if items.empty?
      puts "\nNo items found with tag '#{tag.name}'"
      return
    end

    puts "\nItems tagged with '#{tag.name}':"
    items.each_with_index do |item, index|
      tags_str = item.tag_names.any? ? " [#{item.tag_names.join(', ')}]" : ""
      puts "#{index + 1}. #{item.created_at} | #{item.name}#{tags_str}"
    end

    print "\nSelect item (number) or 0 to go back: "
    input = gets.chomp

    return if input == '0'

    choice = input.to_i
    if choice.between?(1, items.length)
      selected_item = items[choice - 1]
      show_item_menu(selected_item)
    else
      puts "Invalid selection."
    end
  end

  def create_item
    puts "\n=== Create New Item ==="

    print "Name: "
    name = gets.chomp
    return if name.empty?

    print "Date (YYYY-MM-DD) [#{Date.today}]: "
    date_input = gets.chomp
    date = date_input.empty? ? Date.today.strftime('%Y-%m-%d') : date_input

    item = Item.new(name: name, created_at: date)
    item.create_folder

    # Tag selection
    selected_tag_ids = select_tags

    print "Description (y/n)? "
    has_description = gets.chomp.downcase == 'y'

    description = ""
    if has_description
      puts "Enter description (press Enter twice to finish):"
      lines = []
      loop do
        line = gets.chomp
        break if line.empty? && !lines.empty?
        lines << line
      end
      description = lines.join("\n")
    end

    item.description = description
    item.save
    item.update_tags(selected_tag_ids)

    puts "Item created successfully!"
    item.open_folder

    # Wait for at least one file to be added to the folder
    puts "\n⚠️  IMPORTANT: Please add at least one file to the opened folder '#{File.basename(item.path)}'."
    puts "You cannot continue until at least one file has been added to the folder."

    loop do
      # Check for actual files (exclude directories and system files)
      files_in_folder = Dir.glob(File.join(item.path, '*')).select do |f|
        File.file?(f) && !File.basename(f).start_with?('.')
      end

      if files_in_folder.any?
        puts "\n✅ Found #{files_in_folder.size} file(s) in the folder. Item creation complete!"
        break
      else
        print "\n⏳ Still waiting for files... Press Enter to check again: "
        gets.chomp
      end
    end
  end

  def select_tags
    tags = Tag.all
    selected_ids = []

    loop do
      puts "\nAvailable Tags:"
      puts "0. Finish"

      tags.each_with_index do |tag, index|
        puts "#{index + 1}. #{tag.name}"
      end

      puts "\nSelected: #{selected_ids.map { |id| tags.find { |t| t.id == id }&.name }.compact.join(', ')}"
      print "Choose tag (0 to finish, number to select, 'new' to add tag): "

      input = gets.chomp

      if input == '0'
        break
      elsif input.downcase == 'new'
        print "New tag name: "
        tag_name = gets.chomp
        if tag_name.strip.empty?
          puts "Tag name cannot be empty."
          next
        end
        new_tag = Tag.find_or_create_by_name(tag_name)
        tags << new_tag unless tags.any? { |t| t.id == new_tag.id }
        selected_ids << new_tag.id
      else
        choice = input.to_i
        if choice.between?(1, tags.length)
          tag_id = tags[choice - 1].id
          if selected_ids.include?(tag_id)
            selected_ids.delete(tag_id)
          else
            selected_ids << tag_id
          end
        else
          puts "Invalid choice."
        end
      end
    end

    selected_ids
  end

  def show_item_menu(item)
    loop do
      puts "\n=== #{item.name} ==="
      puts "Date: #{item.created_at}"
      puts "Tags: [#{item.tag_names.map { |tag| "\"#{tag}\"" }.join(', ')}]"

      if item.description && !item.description.strip.empty?
        puts ""
        item.description.each_line do |line|
          puts "| #{line.rstrip}"
        end
      end
      puts "\n1. Open folder"
      puts "2. Edit"
      puts "9. Delete item"
      puts "0. Back to search results"
      print "Choose an option: "

      input = gets.chomp

      case input
      when '0'
        break
      when '1'
        item.open_folder
      when '2'
        edit_item(item)
      when '9'
        if confirm_delete(item)
          item.destroy
          puts "Item deleted successfully."
          break
        end
      else
        puts "Invalid option."
      end
    end
  end

  def edit_item(item)
    puts "\n=== Edit Item ==="

    print "Name [#{item.name}]: "
    new_name = gets.chomp
    item.name = new_name unless new_name.empty?

    print "Date (YYYY-MM-DD) [#{item.created_at}]: "
    date_input = gets.chomp
    item.created_at = date_input unless date_input.empty?

    # Tag selection
    selected_tag_ids = select_tags
    item.update_tags(selected_tag_ids) unless selected_tag_ids.empty?

    print "Update description (y/n)? "
    update_desc = gets.chomp.downcase == 'y'

    if update_desc
      puts "\nCurrent description:"
      if item.description && !item.description.strip.empty?
        item.description.each_line do |line|
          puts "| #{line.rstrip}"
        end
      else
        puts "(no description)"
      end

      puts "\nEnter new description (press Enter twice to finish, or just Enter to keep current):"
      lines = []
      loop do
        line = gets.chomp
        break if line.empty? && !lines.empty?
        lines << line
      end

      new_description = lines.join("\n")
      item.description = new_description unless new_description.strip.empty?
    end

    item.save
    puts "Item updated successfully!"

    # Show the updated item
    puts "\n=== #{item.name} ==="
    puts "Date: #{item.created_at}"
    puts "Tags: [#{item.tag_names.map { |tag| "\"#{tag}\"" }.join(', ')}]"

    if item.description && !item.description.strip.empty?
      puts ""
      item.description.each_line do |line|
        puts "| #{line.rstrip}"
      end
    end
  end

  def confirm_delete(item)
    print "Are you sure you want to delete '#{item.name}'? (y/n): "
    gets.chomp.downcase == 'y'
  end
end

# Run the application
if __FILE__ == $0 || defined?(KORA_EXECUTABLE)
  CLI.new.run
end
