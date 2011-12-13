require 'rgen/environment'
require 'rgen/util/file_change_detector'
require 'rgen/fragment/model_fragment'
require 'rtext/instantiator'

module RText

# Loads RText files into a FragmentedModel.
#
# A glob pattern or file provider specifies the files which should be loaded. The load method
# can be called to load and to reload the model. Only changed files will be reloaded. 
#
# Optionally, the loader can use a fragment cache to speed up loading.
#
class DefaultLoader

  # Create a default loader for +language+, loading into +fragmented_model+.
  # It will find files either by evaluating the glob pattern given with +:pattern+ 
  # (see Dir.glob) or by means of a +file_provider+. Options:
  #
  #  :pattern
  #    a glob pattern or an array of glob patterns
  #    alternatively, a +:file_provider+ may be specified
  #
  #  :file_provider
  #    a proc which is called without any arguments and should return the files to load
  #    this is an alternative to providing +:pattern+
  #
  #  :cache
  #    a fragment cache to be used for loading
  #
  def initialize(language, fragmented_model, options={})
    @lang = language
    @model = fragmented_model
    @change_detector = RGen::Util::FileChangeDetector.new(
      :file_added => method(:file_added),
      :file_removed => method(:file_removed),
      :file_changed => method(:file_changed))
    @cache = options[:cache]
    @fragment_by_file = {}
    pattern = options[:pattern]
    @file_provider = options[:file_provider] || proc { Dir.glob(pattern) }
  end

  # Loads or reloads model fragments from files using the file patterns or file provider 
  # specified in the constructor. Options:
  #
  #  :before_load
  #    a proc which is called before a file is actually loaded, receives the fragment to load
  #    into and a symbol indicating the kind of loading: :load, :load_cached, :load_update_cache
  #    default: no before load proc
  # 
  def load(options={})
    @before_load_proc = options[:before_load]
    files = @file_provider.call 
    @change_detector.check_files(files)
    @model.resolve(method(:fragment_provider))
  end

  private

  def file_added(file)
    fragment = RGen::Fragment::ModelFragment.new(file, 
      :identifier_provider => @lang.identifier_provider)
    load_fragment_cached(fragment)
    @model.add_fragment(fragment)
    @fragment_by_file[file] = fragment
  end

  def file_removed(file)
    @model.remove_fragment(@fragment_by_file[file])
    @fragment_by_file.delete(file)
  end

  def file_changed(file)
    file_removed(file)
    file_added(file)
  end

  def fragment_provider(element)
    fr = @lang.fragment_ref(element)
    fr && fr.fragment
  end

  def load_fragment_cached(fragment)
    if @cache
      begin
        result = @cache.load(fragment)
      rescue ArgumentError => e
        # Marshal#load raises an ArgumentError if required classes are not present
        if e.message =~ /undefined class\/module/
          result = :invalid
        else
          raise
        end
      end
      if result == :invalid
        @before_load_proc && @before_load_proc.call(fragment, :load_update_cache)
        load_fragment(fragment)
        @cache.store(fragment)
      else
        @before_load_proc && @before_load_proc.call(fragment, :load_cached)
      end
    else
      @before_load_proc && @before_load_proc.call(fragment, :load)
      load_fragment(fragment)
    end
  end

  def load_fragment(fragment)
    env = RGen::Environment.new
    urefs = []
    problems = []
    root_elements = []
    inst = RText::Instantiator.new(@lang)
    File.open(fragment.location) do |f|
      inst.instantiate(f.read,
        :env => env,
        :unresolved_refs => urefs,
        :problems => problems,
        :root_elements => root_elements,
        :fragment_ref => fragment.fragment_ref,
        :file_name => fragment.location)
    end
    fragment.data = {:problems => problems}
    fragment.set_root_elements(root_elements,
      :unresolved_refs => urefs, 
      :elements => env.elements)
    fragment.build_index
    fragment.resolve_local
  end

end

end

