#!/usr/bin/env ruby
# frozen_string_literal: true

# Agent SkillのfrontmatterをRuby標準のPsychで安全にYAML解析する。
require "yaml"

abort "usage: #{$PROGRAM_NAME} SKILL.md..." if ARGV.empty?

ARGV.each do |path|
  content = File.read(path, encoding: "UTF-8")
  match = content.match(/\A---\r?\n(.*?)\r?\n---\r?\n/m)
  abort "#{path}: YAML frontmatterが先頭にないか、閉じられていません" unless match

  begin
    metadata = YAML.safe_load(
      match[1],
      permitted_classes: [],
      permitted_symbols: [],
      aliases: false
    )
  rescue Psych::Exception => error
    abort "#{path}: YAML frontmatterを解析できません: #{error.message}"
  end

  abort "#{path}: frontmatterがmappingではありません" unless metadata.is_a?(Hash)

  %w[name description].each do |key|
    value = metadata[key]
    abort "#{path}: #{key}が空です" unless value.is_a?(String) && !value.strip.empty?
  end
end
