#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

ruby <<'RUBY'
def load_table(path)
  pairs = File.read(path).scan(/^"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";/)
  table = pairs.to_h
  abort "duplicate localization key in #{path}" unless pairs.length == table.length
  table
end

english = load_table("Resources/en.lproj/Localizable.strings")
chinese = load_table("Resources/zh-Hans.lproj/Localizable.strings")

missing_english = chinese.keys - english.keys
missing_chinese = english.keys - chinese.keys
abort "English localization is missing: #{missing_english.join(', ')}" unless missing_english.empty?
abort "Chinese localization is missing: #{missing_chinese.join(', ')}" unless missing_chinese.empty?

english_leaks = english.select { |_, value| value.match?(/[一-龥]/) }
abort "English localization contains Chinese text: #{english_leaks.keys.join(', ')}" unless english_leaks.empty?

chinese_gaps = chinese.select { |key, value| key.match?(/[一-龥]/) && !value.match?(/[一-龥]/) }
abort "Chinese localization lost its Chinese translation: #{chinese_gaps.keys.join(', ')}" unless chinese_gaps.empty?

empty_values = (english.merge(chinese)).select { |_, value| value.empty? }
abort "Localization contains empty values: #{empty_values.keys.join(', ')}" unless empty_values.empty?

format_tokens = ->(value) { value.scan(/%(?:\d+\$)?(?:@|d|ld|lld|llu|u|f)/).map { |token| token.sub(/%\d+\$/, "%") }.sort }
format_mismatches = english.keys.select do |key|
  format_tokens.call(key) != format_tokens.call(english.fetch(key)) ||
    format_tokens.call(key) != format_tokens.call(chinese.fetch(key))
end
abort "Localization format placeholders do not match: #{format_mismatches.join(', ')}" unless format_mismatches.empty?

source_literals = Dir["Sources/AgentNestApp/*.swift"].flat_map do |path|
  File.read(path).scan(/"((?:\\.|[^"\\])*)"/m).flatten
end
chinese_literals = source_literals.select { |value| value.match?(/[一-龥]/) }.uniq
unregistered = chinese_literals.reject { |key| english.key?(key) && chinese.key?(key) }
abort "App text is not registered in both localizations: #{unregistered.join(', ')}" unless unregistered.empty?

interpolated_chinese = chinese_literals.select { |value| value.include?("\\(") }
abort "Interpolated Chinese text must use AppModel.localized formatting: #{interpolated_chinese.join(', ')}" unless interpolated_chinese.empty?

localized_keys = Dir["Sources/AgentNestApp/*.swift"].flat_map do |path|
  File.read(path).scan(/localized\(\s*"((?:\\.|[^"\\])*)"/m).flatten
end.uniq
missing_localized_keys = localized_keys.reject { |key| english.key?(key) && chinese.key?(key) }
abort "Runtime localization key is missing: #{missing_localized_keys.join(', ')}" unless missing_localized_keys.empty?

localized_bypasses = Dir["Sources/AgentNestApp/*.swift"].select do |path|
  File.read(path).include?("String(localized:")
end
abort "String(localized:) bypasses the selected app language: #{localized_bypasses.join(', ')}" unless localized_bypasses.empty?

core_chinese_literals = Dir["Sources/AgentNestCore/**/*.swift"].reject do |path|
  path.end_with?("HistoryPDFRenderer.swift")
end.flat_map do |path|
  File.read(path).scan(/"((?:\\.|[^"\\])*)"/m).flatten.select { |value| value.match?(/[一-龥]/) }
end.uniq
abort "Core must return structured or language-neutral presentation data: #{core_chinese_literals.join(', ')}" unless core_chinese_literals.empty?

puts "i18n checks passed (#{english.length} keys, no English Chinese-text leaks)"
RUBY
