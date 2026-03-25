# -*- encoding : utf-8 -*-
########################################################
## Thoughts from reading the ISO 32000-1:2008
## this file is part of the CombinePDF library and the code
## is subject to the same license.
########################################################

module CombinePDF
  class PDF
    protected

    include Renderer

    # Scans a page's content streams (inflating FlateDecode where needed) and
    # returns a Hash of Sets identifying every resource name actually invoked:
    #
    #   { xobject: Set["Img1", "Fm2"], font: Set["F1"], extgstate: Set["GS0"] }
    #
    # PDF content-stream operators tracked (mirrors PDFium's
    # RecordPageObjectResourceUsage + Handle_ExecuteXObject/Handle_SetExtendGraphState):
    #   /Name Do     → XObject (images, forms)
    #   /Name <sz> Tf → Font
    #   /Name gs     → ExtGState
    #
    # The scanner strips string literals and inline image data before matching,
    # preventing false positives from operator-like text inside strings or binary
    # image data — matching PDFium's parser-level operator awareness.
    #
    # For Form XObjects referenced via Do, the method recursively scans their
    # own content streams (and their own /Resources if present) so that
    # deeply-nested resource usage is captured — matching PDFium's AddForm →
    # form->ParseContent recursive descent.
    def _extract_do_references(page)
      refs = {xobject: Set.new, font: Set.new, extgstate: Set.new}

      # Gather content stream blobs
      content_streams = _collect_content_streams(page[:Contents])
      content_streams.each do |raw, filter|
        data = _inflate_stream(raw, filter)
        _scan_stream_for_resource_names(data, refs)
      end

      # Recursively scan any referenced Form XObjects, since a Form's own
      # content stream may invoke additional resources by name.
      # PDFium does this via AddForm → CPDF_Form::ParseContent with the
      # Form's own Resources dict.
      resources = page[:Resources]
      return refs unless resources.is_a?(Hash)
      resources = resources[:referenced_object] || resources

      _scan_form_xobjects_recursive(resources, refs)

      refs
    end

    # Recursively scans Form XObjects' content streams for resource references.
    # A Form XObject can have its own /Resources dict (independent of the page),
    # and those resources may reference further Form XObjects. This matches
    # PDFium's recursive ParseContent call inside AddForm.
    def _scan_form_xobjects_recursive(page_resources, refs)
      xobjects = page_resources[:XObject]
      return unless xobjects.is_a?(Hash)
      xobjects = xobjects[:referenced_object] || xobjects

      visited = Set.new
      queue = refs[:xobject].to_a.dup
      while queue.any?
        name = queue.shift
        next if visited.include?(name)
        visited << name

        form_obj = xobjects[name.to_sym]
        next unless form_obj.is_a?(Hash)
        form_obj = form_obj[:referenced_object] || form_obj
        next unless form_obj[:Subtype] == :Form && form_obj[:raw_stream_content]

        form_stream = _inflate_stream(form_obj[:raw_stream_content], form_obj[:Filter])
        before_xobj = refs[:xobject].dup
        _scan_stream_for_resource_names(form_stream, refs)

        # If the Form has its own /Resources/XObject dict, scan those too
        form_resources = form_obj[:Resources]
        if form_resources.is_a?(Hash)
          form_resources = form_resources[:referenced_object] || form_resources
          form_xobjects = form_resources[:XObject]
          if form_xobjects.is_a?(Hash)
            form_xobjects = form_xobjects[:referenced_object] || form_xobjects
            # Merge form-level XObjects into our lookup so recursive scan can find them
            form_xobjects.each do |k, v|
              next if PRIVATE_HASH_KEYS.include?(k)
              xobjects[k] = v unless xobjects.key?(k)
            end
          end
        end

        # Enqueue newly-discovered XObject names for recursive scan
        (refs[:xobject] - before_xobj).each {|n| queue << n}
      end
    end

    # Scans a binary content-stream string for PDF operators that reference
    # named resources and adds the names to the appropriate set in +refs+.
    #
    # Before scanning, strips string literals ( (...) and <...> ) and inline
    # image data ( BI...ID <bytes> EI ) to avoid false positives from
    # operator-like text inside non-operator data. This mirrors PDFium's
    # behavior where the stream content parser only recognizes operators
    # at the operator level, never inside string operands or image data.
    def _scan_stream_for_resource_names(data, refs)
      clean = _strip_non_operator_data(data)
      # /Name Do  — XObject invocation (PDFium: Handle_ExecuteXObject)
      clean.scan(%r{/([\w.+\-]+)\s+Do(?:\s|$)}) {|m| refs[:xobject] << m[0]}
      # /Name <size> Tf  — Font selection (PDFium: Handle_SetFont)
      clean.scan(%r{/([\w.+\-]+)\s+[\d.]+\s+Tf(?:\s|$)}) {|m| refs[:font] << m[0]}
      # /Name gs  — ExtGState (PDFium: Handle_SetExtendGraphState)
      clean.scan(%r{/([\w.+\-]+)\s+gs(?:\s|$)}) {|m| refs[:extgstate] << m[0]}
    end

    # Strips string literals and inline image data from a PDF content stream
    # to prevent false-positive operator matches. Returns a cleaned copy.
    #
    # Handles:
    #   - Literal strings: ( ... ) with balanced parentheses and \) escapes
    #   - Hex strings: < ... >  (but not dictionary delimiters <<...>>)
    #   - Inline images: BI <key/value pairs> ID <binary data> EI
    def _strip_non_operator_data(data)
      result = data.b.dup
      # 1. Strip inline images (BI ... ID <binary> EI)
      #    ID is followed by a single whitespace byte, then binary data until
      #    a whitespace + EI + whitespace/EOF sequence.
      result.gsub!(/\bBI\b.*?\bID[\s].*?[\s]EI(?:\s|$)/m, " ")
      # 2. Strip literal strings with balanced parens
      #    PDF strings can nest: (hello (world)) is valid.
      #    We iteratively strip innermost (...) groups.
      loop do
        break unless result.gsub!(/\((?:[^()\\]|\\.)*\)/m, " ")
      end
      # 3. Strip hex strings (< ... >) but not dict delimiters (<< ... >>)
      result.gsub!(/<(?!<)[^>]*>/, " ")
      result
    end

    # Collects raw stream blobs and their filters from a :Contents value,
    # which may be a single Hash, an Array of Hashes, or indirect refs.
    # Returns Array of [raw_bytes, filter] pairs.
    def _collect_content_streams(contents)
      streams = []
      items = contents.is_a?(Array) ? contents : [contents]
      items.each do |item|
        next unless item.is_a?(Hash)
        obj = item[:referenced_object] || item
        # Handle indirect_without_dictionary wrappers
        obj = obj[:indirect_without_dictionary] if obj.is_a?(Hash) && obj[:indirect_without_dictionary].is_a?(Array)
        if obj.is_a?(Array)
          obj.each do |sub|
            next unless sub.is_a?(Hash)
            sub = sub[:referenced_object] || sub
            streams << [sub[:raw_stream_content], sub[:Filter]] if sub[:raw_stream_content]
          end
        elsif obj.is_a?(Hash) && obj[:raw_stream_content]
          streams << [obj[:raw_stream_content], obj[:Filter]]
        end
      end
      streams
    end

    # Inflates a raw stream if it uses FlateDecode. Returns the binary string.
    def _inflate_stream(raw, filter)
      return raw.dup unless raw && filter
      filters = filter.is_a?(Array) ? filter : [filter]
      data = raw.dup
      filters.each do |f|
        next unless f == :FlateDecode
        begin
          data = Zlib::Inflate.inflate(data)
        rescue Zlib::DataError, Zlib::BufError
          # If inflation fails, fall through with raw bytes — the Do scan may
          # still match if the stream happens to be stored uncompressed.
          break
        end
      end
      data
    end

    # Creates a shallow copy of a page Hash with its own Resources chain.
    # The copy shares :Contents streams and actual resource objects (images,
    # fonts, etc.) but owns its own:
    #   - Page hash
    #   - :Resources wrapper + inner dict
    #   - :XObject, :Font, :ExtGState sub-dicts
    #
    # This mirrors PDFium's CPDF_PageExporter::ExportPages() which deep-clones
    # the page dictionary into the destination document, combined with
    # CloneResourcesDictEntries() which ensures sub-dicts are not shared.
    #
    # The page hash is duped (shallow) so that setting page[:Resources] on the
    # copy does NOT modify the original source page. Contents, MediaBox, etc.
    # remain shared references (they are read-only during pruning).
    def _shallow_copy_page(page)
      copy = page.dup
      copy.extend(Page_Methods) unless copy.is_a?(Page_Methods)
      _isolate_page_resources(copy)
      copy
    end

    # Isolates a page's Resources chain so that mutations do not affect
    # other pages or the source parsed PDF. Creates shallow dups of:
    #   1. The :Resources wrapper (or referenced_object)
    #   2. Each resource sub-dict (:XObject, :Font, :ExtGState)
    #
    # This mirrors PDFium's IsPageResourceShared() + CloneResourcesDictEntries()
    # pattern in cpdf_pagecontentgenerator.cpp:UpdateResourcesDict().
    def _isolate_page_resources(page)
      res_wrapper = page[:Resources]
      return unless res_wrapper.is_a?(Hash)

      # Dup the wrapper and the inner dict
      if res_wrapper[:referenced_object].is_a?(Hash)
        new_wrapper = res_wrapper.dup
        new_wrapper[:referenced_object] = res_wrapper[:referenced_object].dup
        page[:Resources] = new_wrapper
        resources = new_wrapper[:referenced_object]
      else
        resources = res_wrapper.dup
        page[:Resources] = resources
      end

      # Dup each resource sub-dict so deletions are isolated
      [:XObject, :Font, :ExtGState].each do |key|
        sub = resources[key]
        next unless sub.is_a?(Hash)
        if sub[:referenced_object].is_a?(Hash)
          new_sub = sub.dup
          new_sub[:referenced_object] = sub[:referenced_object].dup
          resources[key] = new_sub
        else
          resources[key] = sub.dup
        end
      end
    end

    # Deletes entries from a page's resource sub-dictionary (e.g. :XObject)
    # that are not in the +keep_names+ set.
    #
    # IMPORTANT: _isolate_page_resources must be called on the page first
    # to prevent mutation of shared/aliased source data.
    #
    # Returns the count of entries removed.
    def _prune_resource_dict(page, dict_key, keep_names)
      resources = page[:Resources]
      return 0 unless resources.is_a?(Hash)
      resources = resources[:referenced_object] || resources

      sub_dict = resources[dict_key]
      return 0 unless sub_dict.is_a?(Hash)
      sub_dict = sub_dict[:referenced_object] || sub_dict
      return 0 unless sub_dict.is_a?(Hash)

      keys_to_delete = []
      sub_dict.each_key do |k|
        next if PRIVATE_HASH_KEYS.include?(k)
        keys_to_delete << k unless keep_names.include?(k.to_s)
      end

      keys_to_delete.each {|k| sub_dict.delete(k)}
      keys_to_delete.length
    end

    # RECORSIVE_PROTECTION = { Parent: true, Last: true}.freeze

    # @private
    # Some PDF objects contain references to other PDF objects.
    #
    # this function adds the references contained in these objects.
    #
    # this is used for internal operations, such as injectng data using the << operator.
    def add_referenced()
      # an existing object map
      resolved = {}.dup
      existing = {}.dup
      should_resolve = [].dup
      #set all existing objects as resolved and register their children for future resolution
      @objects.each { |obj| existing[obj.object_id] = obj ; resolved[obj.object_id] = obj; should_resolve << obj.values}
      # loop until should_resolve is empty
      while should_resolve.any?
        obj = should_resolve.pop
        next if resolved[obj.object_id] # the object exists
        if obj.is_a?(Hash)
          referenced = obj[:referenced_object]
          if referenced && referenced.any?
            tmp = resolved[referenced.object_id]
            if !tmp && referenced[:raw_stream_content]
              tmp = existing[referenced[:raw_stream_content].object_id]
              # Avoid endless recursion by limiting it to a number of layers (default == 2)
              tmp = nil unless equal_layers(tmp, referenced)
            end
            if tmp
              obj[:referenced_object] = tmp
            else
              resolved[obj.object_id] = referenced
              #        existing[referenced] = referenced
              existing[referenced[:raw_stream_content].object_id] = referenced
              should_resolve << referenced
              @objects << referenced
            end
          else
            resolved[obj.object_id] = obj
            obj.keys.each { |k| should_resolve << obj[k] unless !obj[k].is_a?(Enumerable) || resolved[obj[k].object_id] }
          end
        elsif obj.is_a?(Array)
          resolved[obj.object_id] = obj
          should_resolve.concat obj
        end
      end
      resolved.clear
      existing.clear
    end

    # @private
    def rebuild_catalog(*with_pages)
      # # build page list v.1 Slow but WORKS
      # # Benchmark testing value: 26.708394
      # old_catalogs = @objects.select {|obj| obj.is_a?(Hash) && obj[:Type] == :Catalog}
      # old_catalogs ||= []
      # page_list = []
      # PDFOperations._each_object(old_catalogs,false) { |p| page_list << p if p.is_a?(Hash) && p[:Type] == :Page }

      # build page list v.2 faster, better, and works
      # Benchmark testing value: 0.215114
      page_list = pages

      # add pages to catalog, if requested
      page_list.concat(with_pages) unless with_pages.empty?

      # duplicate any non-unique pages - This is a special case to resolve Adobe Acrobat Reader issues (see issues #19 and #81)
      uniqueness = {}.dup
      page_list.each { |page| page = page[:referenced_object] || page; page = page.dup if uniqueness[page.object_id]; uniqueness[page.object_id] = page }
      page_list.clear
      page_list = uniqueness.values
      uniqueness.clear

      # build new Pages object
      page_object_kids = [].dup
      pages_object = { Type: :Pages, Count: page_list.length, Kids: page_object_kids }
      pages_object_reference = { referenced_object: pages_object, is_reference_only: true }
      page_list.each { |pg| pg[:Parent] = pages_object_reference; page_object_kids << ({ referenced_object: pg, is_reference_only: true }) }

      # rebuild/rename the names dictionary
      rebuild_names
      # build new Catalog object
      catalog_object = { Type: :Catalog,
                         Pages: { referenced_object: pages_object, is_reference_only: true } }
      # pages_object[:Parent] = { referenced_object: catalog_object, is_reference_only: true } # causes AcrobatReader to fail
      catalog_object[:ViewerPreferences] = @viewer_preferences unless @viewer_preferences.empty?

      # point old Pages pointers to new Pages object
      ## first point known pages objects - enough?
      pages.each { |p| p[:Parent] = { referenced_object: pages_object, is_reference_only: true } }
      ## or should we, go over structure? (fails)
      # each_object {|obj| obj[:Parent][:referenced_object] = pages_object if obj.is_a?(Hash) && obj[:Parent].is_a?(Hash) && obj[:Parent][:referenced_object] && obj[:Parent][:referenced_object][:Type] == :Pages}

      # # remove old catalog and pages objects
      # @objects.reject! { |obj| obj.is_a?(Hash) && (obj[:Type] == :Catalog || obj[:Type] == :Pages) }
      # remove old objects list and trees
      @objects.clear

      # inject new catalog and pages objects
      @objects << @info if @info
      @objects << catalog_object
      # @objects << pages_object

      # rebuild/rename the forms dictionary
      if @forms_data.nil? || @forms_data.empty?
        @forms_data = nil
      else
        @forms_data = { referenced_object: (@forms_data[:referenced_object] || @forms_data), is_reference_only: true }
        catalog_object[:AcroForm] = @forms_data
        @objects << @forms_data[:referenced_object]
      end

      # add the names dictionary
      if @names && @names.length > 1
        @objects << @names
        catalog_object[:Names] = { referenced_object: @names, is_reference_only: true }
      end
      # add the outlines dictionary
      if @outlines && @outlines.any?
        @objects << @outlines
        catalog_object[:Outlines] = { referenced_object: @outlines, is_reference_only: true }
      end

      catalog_object
    end

    # Deprecation Notice
    def names_object
      puts "CombinePDF Deprecation Notice: the protected method `names_object` will be deprecated in the upcoming version. Use `names` instead."
      @names
    end

    def outlines_object
      puts "CombinePDF Deprecation Notice: the protected method `outlines_object` will be deprecated in the upcoming version. Use `oulines` instead."
      @outlines
    end
    # def forms_data
    # 	@forms_data
    # end

    # @private
    # this is an alternative to the rebuild_catalog catalog method
    # this method is used by the to_pdf method, for streamlining the PDF output.
    # there is no point is calling the method before preparing the output.
    def rebuild_catalog_and_objects
      catalog = rebuild_catalog
      catalog[:Pages][:referenced_object][:Kids].each { |e| @objects << e[:referenced_object]; e[:referenced_object] }
      # adds every referenced object to the @objects (root), addition is performed as pointers rather then copies
      add_referenced()
      catalog
    end

    def get_existing_catalogs
      (@objects.select { |obj| obj.is_a?(Hash) && obj[:Type] == :Catalog }) || (@objects.select { |obj| obj.is_a?(Hash) && obj[:Type] == :Page })
    end

    # end
    # @private
    def renumber_object_ids(start = nil)
      @set_start_id = start || @set_start_id
      start = @set_start_id
      # history = {}
      @objects.each do |obj|
        obj[:indirect_reference_id] = start
        start += 1
      end
    end

    def remove_old_ids
      @objects.each { |obj| obj.delete(:indirect_reference_id); obj.delete(:indirect_generation_number) }
    end

    POSSIBLE_NAME_TREES = [:Dests, :AP, :Pages, :IDS, :Templates, :URLS, :JavaScript, :EmbeddedFiles, :AlternatePresentations, :Renditions].to_set.freeze

    def rebuild_names(name_tree = nil, base = 'CombinePDF_0000000')
      if name_tree
        return nil unless name_tree.is_a?(Hash)
        name_tree = name_tree[:referenced_object] || name_tree
        dic = []
        # map a names tree and return a valid name tree. Do not recourse.
        should_resolve = [name_tree[:Kids], name_tree[:Names]]
        resolved = [].to_set
        while should_resolve.any?
          pos = should_resolve.pop
          if pos.is_a? Array
            next if resolved.include?(pos.object_id)
            if pos[0].is_a? String
              (pos.length / 2).times do |i|
                dic << (pos[i * 2].clear << base.next!)
                pos[(i * 2) + 1][0] = {is_reference_only: true, referenced_object: pages[pos[(i * 2) + 1][0]]} if(pos[(i * 2) + 1].is_a?(Array) && pos[(i * 2) + 1][0].is_a?(Numeric))
                dic << (pos[(i * 2) + 1].is_a?(Array) ? { is_reference_only: true, referenced_object: { indirect_without_dictionary: pos[(i * 2) + 1] } } : pos[(i * 2) + 1])
                # dic << pos[(i * 2) + 1]
              end
            else
              should_resolve.concat pos
            end
          elsif pos.is_a? Hash
            pos = pos[:referenced_object] || pos
            next if resolved.include?(pos.object_id)
            should_resolve << pos[:Kids] if pos[:Kids]
            should_resolve << pos[:Names] if pos[:Names]
          end
          resolved << pos.object_id
        end
        return { referenced_object: { Names: dic }, is_reference_only: true }
      end
      @names ||= @names[:referenced_object]
      new_names = { Type: :Names }.dup
      POSSIBLE_NAME_TREES.each do |ntree|
        if @names[ntree]
          new_names[ntree] = rebuild_names(@names[ntree], base)
          @names[ntree].clear
        end
      end
      @names.clear
      @names = new_names
    end

    # @private
    # this method reviews a Hash and updates it by merging Hash data,
    # preffering the new over the old.
    # def self.hash_merge_new_no_page(_key = nil, old_data = nil, new_data = nil)
    #   return old_data unless new_data
    #   return new_data unless old_data
    #   if old_data.is_a?(Hash) && new_data.is_a?(Hash)
    #     return old_data if (old_data[:Type] == :Page)
    #     old_data.merge(new_data, &(@hash_merge_new_no_page_proc ||= method(:hash_merge_new_no_page)))
    #   elsif old_data.is_a? Array
    #     return old_data + new_data if new_data.is_a?(Array)
    #     return old_data.dup << new_data
    #   elsif new_data.is_a? Array
    #     new_data + [old_data]
    #   else
    #     new_data
    #   end
    # end

    # @private
    # JRuby Alternative this method reviews a Hash and updates it by merging Hash data,
    # preffering the new over the old.
    HASH_MERGE_NEW_NO_PAGE = Proc.new do |_key = nil, old_data = nil, new_data = nil|
      if !new_data
        old_data
      elsif !old_data
        new_data
      elsif old_data.is_a?(Hash) && new_data.is_a?(Hash)
        if (old_data[:Type] == :Page)
          old_data
        else
          old_data.merge(new_data, &HASH_MERGE_NEW_NO_PAGE)
        end
      elsif old_data.is_a? Array
        if new_data.is_a?(Array)
          old_data + new_data
        else
          old_data.dup << new_data
        end
      elsif new_data.is_a? Array
        new_data + [old_data]
      else
        new_data
      end
    end

    # Merges 2 outlines by appending one to the end or start of the other.
    # old_data - the main outline, which is also the one that will be used in the resulting PDF.
    # new_data - the outline to be appended
    # position - an integer representing the position where a PDF is being inserted.
    #            This method only differentiates between inserted at the beginning, or not.
    #            Not at the beginning, means the new outline will be added to the end of the original outline.
    # An outline base node (tree base) has :Type, :Count, :First, :Last
    # Every node within the outline base node's :First or :Last can have also have the following pointers to other nodes:
    # :First or :Last (only if the node has a subtree / subsection)
    # :Parent (the node's parent)
    # :Prev, :Next (previous and next node)
    # Non-node-pointer data in these nodes:
    # :Title - the node's title displayed in the PDF outline
    # :Count - Number of nodes in it's subtree (0 if no subtree)
    # :Dest  - node link destination (if the node is linking to something)
    def merge_outlines(old_data, new_data, position)
      old_data = actual_object(old_data)
      new_data = actual_object(new_data)
      if old_data.nil? || old_data.empty? || old_data[:First].nil?
        # old_data is a reference to the actual object,
        # so if we update old_data, we're done, no need to take any further action
        old_data.update new_data
      elsif new_data.nil? || new_data.empty? || new_data[:First].nil?
        return old_data
      else
        new_data = new_data.dup # avoid old data corruption
        # number of outline nodes, after the merge
        old_data[:Count] = old_data[:Count].to_i + new_data[:Count].to_i
        # walk the Hash here ...
        # I'm just using the start / end insert-position for now...
        # first  - is going to be the start of the outline base node's :First, after the merge
        # last   - is going to be the end   of the outline base node's :Last,  after the merge
        # median - the start of what will be appended to the end of the outline base node's :First
        # parent - the outline base node of the resulting merged outline
        # FIXME implement the possibility to insert somewhere in the middle of the outline
        prev = nil
        pos = first = actual_object((position.nonzero? ? old_data : new_data)[:First])
        last = actual_object((position.nonzero? ? new_data : old_data)[:Last])
        median = { is_reference_only: true, referenced_object: actual_object((position.nonzero? ? new_data : old_data)[:First]) }
        old_data[:First] = { is_reference_only: true, referenced_object: first }
        old_data[:Last] = { is_reference_only: true, referenced_object: last }
        parent = { is_reference_only: true, referenced_object: old_data }
        # Guard against circular references in the outline linked list.
        # PDFs with malformed bookmarks can have :Next pointers that loop back
        # to an earlier node, causing an infinite loop. Use a visited set
        # to detect and break cycles.
        #
        # Inspired by PDFium's FindBookmark() visited-set pattern:
        #   https://pdfium.googlesource.com/pdfium.git/+/refs/heads/chromium/7435/fpdfsdk/fpdf_doc.cpp#60
        # And PDFium's GetNextSibling() self-reference guard:
        #   https://pdfium.googlesource.com/pdfium.git/+/refs/heads/chromium/7435/core/fpdfdoc/cpdf_bookmarktree.cpp#36
        visited = {}.dup
        while pos
          break if visited[pos.object_id]
          visited[pos.object_id] = true
          # walking through old_data here and updating the :Parent as we go,
          # this updates the inserted new_data :Parent's as well once it is appended and the
          # loop keeps walking the appended data.
          pos[:Parent] = parent if pos[:Parent]
          # connect the two outlines
          # if there is no :Next, the end of the outline base node's :First is reached and this is
          # where the new data gets appended, the same way you would append to a two-way linked list.
          if pos[:Next].nil?
            median[:referenced_object][:Prev] = { is_reference_only: true, referenced_object: prev } if median
            pos[:Next] = median
            # midian becomes 'nil' because this loop keeps going after the appending is done,
            # to update the parents of the appended tree and we wouldn't want to keep appending it infinitely.
            median = nil
          end
          # iterating over the outlines main nodes (this is not going into subtrees)
          # while keeping every rotations previous node saved
          prev = pos
          pos = actual_object(pos[:Next])
        end
        # make sure the last object doesn't have the :Next and the first no :Prev property
        prev.delete :Next
        actual_object(old_data[:First]).delete :Prev
      end
    end

    # Build a lookup Hash mapping page object_id to its 1-based index
    def outline_build_page_index_by_object_id
      mapping = {}
      pages.each_with_index do |p, i|
        mapping[actual_object(p).object_id] = i + 1
      end
      mapping
    end

    # Resolve a node's page number using its :Dest, or fallback to the first child's page
    def outline_node_page_number(node, page_index_by_object_id)
      node = actual_object(node)
      dest = node[:Dest]
      if dest && dest.is_a?(Array)
        dest_page_ref = dest[0]
        if dest_page_ref && dest_page_ref.is_a?(Hash)
          page_obj = actual_object(dest_page_ref)
          return page_index_by_object_id[page_obj.object_id]
        end
      end
      if node[:First]
        child = actual_object(node[:First])
        return outline_node_page_number(child, page_index_by_object_id)
      end
      nil
    end

    # Collect siblings starting from :First following :Next
    def outline_collect_siblings(first_ref)
      siblings = []
      cursor = actual_object(first_ref)
      while cursor
        siblings << cursor
        cursor = cursor[:Next] ? actual_object(cursor[:Next]) : nil
      end
      siblings
    end

    # Recursively sort siblings for each outline grouper by page number and rewire links
    def outline_sort_group_by_page(parent_node, page_index_by_object_id)
      parent_node = actual_object(parent_node)
      first_ref = parent_node[:First]
      return unless first_ref

      siblings = outline_collect_siblings(first_ref)

      siblings.sort_by! do |n|
        pn = outline_node_page_number(n, page_index_by_object_id)
        pn ? pn : Float::INFINITY
      end

      siblings.each_with_index do |n, idx|
        if idx.zero?
          n.delete(:Prev)
        else
          n[:Prev] = { is_reference_only: true, referenced_object: siblings[idx - 1] }
        end

        if idx == siblings.length - 1
          n.delete(:Next)
        else
          n[:Next] = { is_reference_only: true, referenced_object: siblings[idx + 1] }
        end
      end

      parent_node[:First] = { is_reference_only: true, referenced_object: siblings.first }
      parent_node[:Last]  = { is_reference_only: true, referenced_object: siblings.last }

      siblings.each do |n|
        outline_sort_group_by_page(n, page_index_by_object_id) if n[:First]
      end
    end

    # Prints the whole outline hash to a file,
    # with basic indentation and replacing raw streams with "RAW STREAM"
    # (subbing doesn't allways work that great for big streams)
    # outline - outline hash
    # file    - "filename.filetype" string
    def print_outline_to_file(outline, file)
      outline_subbed_str = outline.to_s.gsub(/\:raw_stream_content=\>"(?:(?!"}).)*+"\}\}/, ':raw_stream_content=> RAW STREAM}}')
      brace_cnt = 0
      formatted_outline_str = ''
      outline_subbed_str.each_char do |c|
        if c == '{'
          formatted_outline_str << "\n" << "\t" * brace_cnt << c
          brace_cnt += 1
        elsif c == '}'
          brace_cnt -= 1
          brace_cnt = 0 if brace_cnt < 0
          formatted_outline_str << c << "\n" << "\t" * brace_cnt
        elsif c == '\n'
          formatted_outline_str << c << "\t" * brace_cnt
        else
          formatted_outline_str << c
        end
      end
      formatted_outline_str << "\n" * 10
      File.open(file, 'w') { |f| f.write(formatted_outline_str) }
    end

    private

    def equal_layers obj1, obj2, layer = CombinePDF.eq_depth_limit
      return true if obj1.object_id == obj2.object_id
      if obj1.is_a? Hash
        return false unless obj2.is_a? Hash
        return false unless obj1.length == obj2.length
        keys = obj1.keys;
        keys2 = obj2.keys;
        return false if (keys - keys2).any? || (keys2 - keys).any?
        return (warn("CombinePDF nesting limit reached") || true) if(layer == 0)
        keys.each {|k| return false unless equal_layers( obj1[k], obj2[k], layer-1) }
      elsif obj1.is_a? Array
        return false unless obj2.is_a? Array
        return false unless obj1.length == obj2.length
        (obj1-obj2).any? || (obj2-obj1).any?
      else
        obj1 == obj2
      end
    end

    def renaming_dictionary(object = nil, dictionary = {})
      object ||= @names
      case object
      when Array
        object.length.times { |i| object[i].is_a?(String) ? (dictionary[object[i]] = (dictionary.last || 'Random_0001').next) : renaming_dictionary(object[i], dictionary) }
      when Hash
        object.values.each { |v| renaming_dictionary v, dictionary }
      end
    end

    def rename_object(object, _dictionary)
      case object
      when Array
        object.length.times { |i| }
      when Hash
      end
    end

    # @private
    # This method runs the process to add a new outline entry to the current
    # (referenced) outline grouper (the grouper is the parent in the tree
    # hierarchy). This method take 2 parameters:
    #
    # page:: the page object to which the outline will point.
    # title:: the title for the outline.
    def add_outline_node(page, title)
      new_outline = new_outline_node(page, title)
      insert_outline_node(new_outline)
      update_children_count(actual_object(new_outline)[:Parent])
      new_outline
    end

    # @private
    # This method generates and returns a new outline object. This method takes
    # 2 parameters:
    #
    # page:: the page to which the outline will point.
    # title:: the title for the outline.
    def new_outline_node(page, title)
      {
        is_reference_only: true,
        referenced_object: {
          Count: 0,
          Title: title,
          Dest: [
            { is_reference_only: true, referenced_object: page },
            :XYZ, nil, nil, nil
          ],
          Parent: {
            is_reference_only: true,
            referenced_object: @current_outline_grouper
          }
        }
      }
    end

    # @private
    # This method inserts a new outline node to the current (referenced)
    # outline grouper (the grouper is the parent in the tree hierarchy). This
    # method takes 1 parameter:
    #
    # outline_node:: the outline node to be inserted in the current outline grouper
    def insert_outline_node(outline_node)
      if outline_grouper_without_children?
        insert_first_outline_child(outline_node)
      elsif outline_grouper_with_only_one_child?
        insert_second_outline_child(outline_node)
      else
        insert_last_outline_child(outline_node)
      end
    end

    # @private
    # This method inserts the first outline node in the current (referenced)
    # outline grouper (the grouper is the parent in the tree hierarchy). This
    # method takes 1 parameter:
    #
    # outline_node:: the outline node to be inserted in the current outline grouper
    def insert_first_outline_child(outline_node)
      @current_outline_grouper[:First] = outline_node
      @current_outline_grouper[:Last] = outline_node
    end

    # @private
    # This method inserts the second outline node in the current (referenced)
    # outline grouper (the grouper is the parent in the tree hierarchy). This
    # method takes 1 parameter:
    #
    # outline_node:: the outline node to be inserted in the current outline grouper
    def insert_second_outline_child(outline_node)
      actual_object(@current_outline_grouper[:First])[:Next] = outline_node
      actual_object(outline_node)[:Prev] = @current_outline_grouper[:First]
      @current_outline_grouper[:Last] = outline_node
    end

    # @private
    # This method inserts one more outline node in the current (referenced)
    # outline grouper (the grouper is the parent in the tree hierarchy), this
    # means that the current grouper has more than 1 outline-child node. This
    # method takes 1 parameter:
    #
    # outline_node:: the outline node to be inserted in the current outline grouper
    def insert_last_outline_child(outline_node)
      actual_object(@current_outline_grouper[:Last])[:Next] = outline_node
      actual_object(outline_node)[:Prev] = @current_outline_grouper[:Last]
      @current_outline_grouper[:Last] = outline_node
    end

    # @private
    # This method is executed recursively to update the children count for the
    # ascendant parents in the tree hierarchy of the outlines. This method takes
    # 1 parameter:
    #
    # outline_grouper:: the outlien grouper to be updated in its children count.
    def update_children_count(outline_grouper)
      if actual_object(outline_grouper)[:Count].nil?
        actual_object(outline_grouper)[:Count] = 0
      end
      actual_object(outline_grouper)[:Count] += 1
      return if outline_root?(outline_grouper)

      update_children_count(actual_object(outline_grouper)[:Parent])
    end

    # @private
    # This method checks if the received outline node is the outline root of
    # PDF document. This method takes 1 parameter:
    #
    # outline_node:: the outline object to be evaluated.
    def outline_root?(outline_node)
      actual_object(outline_node)[:Parent].nil?
    end

    # @private
    # This method returns true if the current (referenced) outline grouper (the
    # grouper is the parent in the tree hierarchy) has no outline-children
    # nodes.
    def outline_grouper_without_children?
      @current_outline_grouper.exclude?(:First)
    end

    # @private
    # This method returns true if the current (referenced) outline grouper (the
    # grouper is the parent in the tree hierarchy) has only one outline-child
    # node.
    def outline_grouper_with_only_one_child?
      @current_outline_grouper[:First].eql?(@current_outline_grouper[:Last])
    end
  end
end
