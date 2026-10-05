# frozen_string_literal: true

require 'mxrb'

abort 'Usage: prepare_vetclinic_edited.rb SOURCE.mpr NEW_DIRECTORY' unless ARGV.length == 2
source, destination = ARGV.map { File.expand_path(_1) }
abort 'Destination already exists' if File.exist?(destination)
Mxrb::Exporter.new(source, destination, mode: :ruby).export!

def replace_source(root, relative, before, after)
  path = File.join(root, relative)
  text = File.read(path)
  raise "Expected source not found in #{relative}" unless text.include?(before)

  File.write(path, text.gsub(before, after))
end

replace_source(destination, 'app/models/vet_clinic/animal.rb', "    persistence true\n", <<~RUBY)
  persistence true
  attribute :clinic_tag, type: :string, mendix_name: "ClinicTag", default: "Ruby edited"
RUBY
replace_source(destination, 'app/services/vet_clinic/act_create_animal.rb',
               'to: "$Name"', %q(to: "'Ruby edited: ' + $Name"))
page = 'app/pages/vet_clinic/animal_overview_page.rb'
replace_source(destination, page, 'Animal Overview', 'Ruby Edited Animals')
button = <<~RUBY
  button "CreateBrowserAnimal", caption: "Create from edited Ruby" do
    on_click microflow: "VetClinic.ACT_CreateAnimal", pass: { "Name" => "'Browser acceptance'" }
  end
RUBY
replace_source(destination, page, '          data_grid(', "#{button}          data_grid(")
puts destination
