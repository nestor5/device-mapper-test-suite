require 'dmtest/log'

#----------------------------------------------------------------

class CacheStatus
  attr_accessor :md_block_size, :md_used, :md_total, :cache_block_size, :residency, :cache_total
  attr_accessor :read_hits, :read_misses, :write_hits, :write_misses
  attr_accessor :demotions, :promotions, :nr_dirty, :features, :core_args, :policy_name, :policy_args, :mode, :needs_check, :fail

  PATTERN ='\d+\s+\d+\s+cache\s+(.*)'

  def initialize(cache_dev)
    status = cache_dev.status

    # it's possible the cache has fallen back to failure mode
    if status.match(/\s*Fail\s*/)
      @fail = true
    else
      m = status.match(PATTERN)
      if m.nil?
        raise "couldn't parse cache status"
      else
        @a = m[1].split

        shift_int :md_block_size
        shift_ratio :md_used, :md_total
        shift_int :cache_block_size
        shift_ratio :residency, :cache_total
        shift_int :read_hits
        shift_int :read_misses
        shift_int :write_hits
        shift_int :write_misses
        shift_int :demotions
        shift_int :promotions
        shift_int :nr_dirty
        shift_features :features
        shift_pairs :core_args
        shift :policy_name
        shift_pairs :policy_args
        shift_mode :mode
        shift_needs_check :needs_check
      end
    end
  end

  private
  def check_args(symbol)
    raise "Insufficient status fields, while trying to read #{symbol}" if @a.size == 0
  end

  def shift_(symbol)
    check_args(symbol)
    @a.shift
  end

  def shift(symbol)
    check_args(symbol)
    set_val(symbol, @a.shift)
  end

  def shift_int_(symbol)
    check_args(symbol)
    Integer(@a.shift)
  end

  def shift_int(symbol)
    check_args(symbol)
    set_val(symbol, Integer(@a.shift))
  end

  def shift_ratio(sym1, sym2)
    str = shift_(sym1)
    a, b = str.split('/')
    set_val(sym1, a.to_i)
    set_val(sym2, b.to_i)
  end

  def shift_features(symbol)
    r = Array.new
    n = shift_int_(symbol)

    if (n > 0)
      1.upto(n) do
        r << shift_(symbol)
      end
    end

    set_val(symbol, r)
  end

  def shift_pairs(symbol)
    r = Array.new

    n = shift_int_(symbol)
    raise "odd number of policy arguments" if n.odd?

    if (n > 0)
        1.upto(n / 2) do
        key = shift_(symbol)
        value = shift_(symbol)
        r << [key, value]
      end
    end

    set_val(symbol, r)
  end

  def set_val(symbol, v)
    self.send("#{symbol}=".intern, v)
  end

  def shift_mode(symbol)
    case shift_(symbol)
    when 'ro' then
      set_val(symbol, :read_only)
    when 'rw' then
      set_val(symbol, :read_write)
    else
      raise "unknown metadata mode"
    end
  end

  def shift_needs_check(symbol)
    case shift_(symbol)
    when 'needs_check' then
      set_val(symbol, true)
    when '-' then
      set_val(symbol, false)
    else
      raise "unknown needs_check value"
    end
  end
end

class CacheTable
  attr_reader :metadata_dev, :cache_dev, :origin_dev, :block_size, :nr_feature_args,
              :feature_args, :policy_name, :nr_policy_args, :policy_args

  # start len "cache" md cd od bs #features feature_arg{1,} #policy_args policy_arg{0,}
  # 0 283115520 cache 254:12 254:13 254:14 512 1 writeback basic 0

  PATTERN ='\d+\s\d+\scache\s([\w:]+)\s([\w:]+)\s([\w:]+)\s(\d+)\s(\d+)\s(.*)'

  def initialize(cache_dev)
    m = cache_dev.table.match(PATTERN)
    if m.nil?
      raise "couldn't parse cache table"
    else
      a = (m[1..-2].to_a + m[-1].to_s.split(/\s+/)).map! { |s| s.strip }
      @metadata_dev,
      @cache_dev,
      @origin_dev,
      @block_size,
      @nr_feature_args = a.shift(3) + [a.shift.to_i] + [a.shift.to_i]
      @feature_args,
      @policy_name,
      @nr_policy_args = [a.shift(@nr_feature_args)] + [a.shift] + [a.shift.to_i]
      @policy_args = a.shift(@nr_policy_args)
    end
  end
end

#----------------------------------------------------------------
