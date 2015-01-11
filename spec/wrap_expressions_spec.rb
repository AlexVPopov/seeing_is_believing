require 'spec_helper'
require 'seeing_is_believing/wrap_expressions'

RSpec.describe SeeingIsBelieving::WrapExpressions do
  def wrap(code, overrides={})
    code = code + "\n" unless code.end_with? "\n"
    described_class.call(code,
      before_all:  ->   { overrides.fetch :before_all,   '' },
      after_all:   ->   { overrides.fetch :after_all,    '' },
      before_each: -> * { overrides.fetch :before_each, '<' },
      after_each:  -> * { overrides.fetch :after_each,  '>' }
    ).chomp
  end

  def wrap_with_body(code, overrides={})
    wrap code, { before_all: '[',
                 after_all:  ']',
               }.merge(overrides)
  end

  def heredoc_wrap(code, overrides={})
    wrap_with_body code, { before_each: '{'.freeze,
                           after_each:  '}'.freeze,
                         }.merge(overrides)
  end


  it 'raises a SyntaxError if the program is invalid' do
    expect { wrap '+' }.to raise_error SyntaxError
  end

  it 'can inject syntax errors with __TOTAL_FUCKING_FAILURE__' do
    expect(wrap('__TOTAL_FUCKING_FAILURE__')).to eq '<.....TOTAL FUCKING FAILURE!.....>'
  end

  describe 'wrapping the body' do
    it 'wraps the entire body, ignoring leading comments and the data segment' do
      expect(wrap_with_body "#comment\nA\n__END__\n1").to eq "#comment\n[<A>]\n__END__\n1"

      # TODO: ist this actually true?
      expect(wrap_with_body "#comment\n__END__\n1").to eq "[]#comment\n__END__\n1"
    end

    it 'wraps when code is an empty string' do
      expect(wrap_with_body '').to eq '[]'
    end

    it 'places body before first comment when there are only comments' do
      expect(wrap_with_body "# abc").to eq "[]# abc"
    end

    it 'places body before trailing comments, but still wraps code' do
      expect(wrap_with_body "1# abc").to eq "[<1>]# abc"
    end

    # this changes the number of lines, annoyingly, though it shouldn't mess anything up,
    # unless you were trying to reopen the file to read it, in which case, *surprise* the whole thing's been rewritten
    it 'injects a newline if there is a data segment and the after block doesn\'t end in a newline' do
      expect(wrap_with_body "__END__").to eq "[]\n__END__"
      expect(wrap_with_body "\n__END__").to eq "[]\n__END__"
      expect(wrap_with_body "\n\n__END__").to eq "[]\n\n__END__"
      expect(wrap_with_body "__END__!").to eq "[<__END__!>]"
      expect(wrap_with_body "%(\n__END__\n)").to eq "[<%(\n__END__\n)>]"
    end

    it 'wraps bodies that are wrapped in parentheses' do
      expect(wrap('(1)')).to eq '<(1)>'
      expect(wrap("(\n<<doc\ndoc\n)")).to eq "<(\n<<<doc>\ndoc\n)>"
    end

    context 'fucking heredocs' do
      example 'single heredoc' do
        expect(heredoc_wrap "<<A\nA").to eq "[{<<A}]\nA"
      end

      example 'multiple heredocs' do
        expect(heredoc_wrap "<<A\nA\n<<B\nB").to eq "[{<<A}\nA\n{<<B}]\nB"
      end

      example 'heredocs as targets and arguments to methods' do
        expect(heredoc_wrap "<<A.size 1\nA").to eq "[{<<A.size 1}]\nA"
        expect(heredoc_wrap "<<A.size\nA").to eq "[{<<A.size}]\nA"
        expect(heredoc_wrap "<<A.size()\nA").to eq "[{<<A.size()}]\nA"
        expect(heredoc_wrap "a.size <<A\nA").to eq "[{a.size <<A}]\nA"
        expect(heredoc_wrap "<<A.size <<B\nA\nB").to eq "[{<<A.size <<B}]\nA\nB"
        expect(heredoc_wrap "<<A.size(<<B)\nA\nB").to eq "[{<<A.size(<<B)}]\nA\nB"
      end
    end

    it 'identifies the last line of the body' do
      expect(wrap_with_body "a\n"\
                            "def b\n"\
                            "  c = 1\n"\
                            "end"
            ).to eq "[<a>\n"\
                    "<def b\n"\
                    "  <c = 1>\n"\
                    "end>]"
    end
  end

  it 'passes the current line number to the before_each and after_each wrappers' do
    pre_line_num = post_line_num = nil
    described_class.call("\na\n",
                         before_each: -> _pre_line_num  { pre_line_num  = _pre_line_num;  '<' },
                         after_each:  -> _post_line_num { post_line_num = _post_line_num; '>' }
                        )
    expect(pre_line_num).to eq 2
    expect(post_line_num).to eq 2
  end

  it 'does nothing for an empty program' do
    expect(wrap("")).to eq "" # note that code will fix the missing newline, and wrap will chomp it from the result for convenience
  end

  it 'ignores comments' do
    expect(wrap "# comment"         ).to eq "# comment"
    expect(wrap "1 #abc\n#def"      ).to eq "<1> #abc\n#def"
    expect(wrap "1\n=begin\n2\n=end").to eq "<1>\n=begin\n2\n=end"
    expect(wrap "=begin\n1\n=end\n2").to eq "=begin\n1\n=end\n<2>"
  end

  # TODO: move this into Code specs
  describe 'void value expressions' do
    def void_value?(ast)
      klass = described_class.new "\n", {}
      klass.__send__(:void_value?, ast)
    end

    def ast_for(code)
      Parser::CurrentRuby.parse code
    end

    it 'knows a `return`, `next`, `redo`, `retry`, and `break` are void values' do
      expect(void_value?(ast_for("def a; return; end").children.last)).to be true
      expect(void_value?(ast_for("loop { next  }"    ).children.last)).to be true
      expect(void_value?(ast_for("loop { redo  }"    ).children.last)).to be true
      expect(void_value?(ast_for("loop { break }"    ).children.last)).to be true

      the_retry = ast_for("begin; rescue; retry; end").children.first.children[1].children.last
      expect(the_retry.type).to eq :retry
      expect(void_value? the_retry).to eq true
    end
    it 'knows an `if` is a void value if either side is a void value' do
      the_if = ast_for("def a; if 1; return 2; else; 3; end; end").children.last
      expect(the_if.type).to eq :if
      expect(void_value?(the_if)).to be true

      the_if = ast_for("def a; if 1; 2; else; return 3; end; end").children.last
      expect(the_if.type).to eq :if
      expect(void_value?(the_if)).to be true

      the_if = ast_for("def a; if 1; 2; else; 3; end; end").children.last
      expect(the_if.type).to eq :if
      expect(void_value?(the_if)).to be false
    end
    it 'knows a begin is a void value if its last element is a void value' do
      the_begin = ast_for("loop { begin; break; end }").children.last
      expect([:begin, :kwbegin]).to include the_begin.type
      expect(void_value?(the_begin)).to be true

      the_begin = ast_for("loop { begin; 1; end }").children.last
      expect([:begin, :kwbegin]).to include the_begin.type
      expect(void_value?(the_begin)).to be false
    end
    it 'knows a rescue is a void value if its last child or its else is a void value' do
      the_rescue = ast_for("begin; rescue; retry; end").children.first
      expect(the_rescue.type).to eq :rescue
      expect(void_value?(the_rescue)).to be true

      the_rescue = ast_for("begin; rescue; 1; else; retry; end").children.first
      expect(the_rescue.type).to eq :rescue
      expect(void_value?(the_rescue)).to be true

      the_rescue = ast_for("begin; rescue; 1; else; 2; end").children.first
      expect(the_rescue.type).to eq :rescue
      expect(void_value?(the_rescue)).to be false
    end
    it 'knows an ensure is a void value if its body or ensure portion are void values' do
      the_ensure = ast_for("loop { begin; break; ensure; 1; end }").children.last.children.last
      expect(the_ensure.type).to eq :ensure
      expect(void_value?(the_ensure)).to be true

      the_ensure = ast_for("loop { begin; 1; ensure; break; end }").children.last.children.last
      expect(the_ensure.type).to eq :ensure
      expect(void_value?(the_ensure)).to be true

      the_ensure = ast_for("loop { begin; 1; ensure; 2; end }").children.last.children.last
      expect(the_ensure.type).to eq :ensure
      expect(void_value?(the_ensure)).to be false
    end
    it 'knows other things are not void values' do
      expect(void_value?(ast_for "123")).to be false
    end
  end

  describe 'basic expressions' do
    it 'wraps an expression' do
      expect(wrap("A")).to eq "<A>"
    end

    it 'wraps multiple expressions' do
      expect(wrap("A\nB")).to eq "<A>\n<B>"
      expect(wrap("(1\n2)")).to eq "<(<1>\n2)>"
      expect(wrap("(1\n2\n)")).to eq "<(<1>\n<2>\n)>"
      expect(wrap("begin\n1\n2\nend")).to eq "<begin\n<1>\n<2>\nend>"
    end

    it 'does not wrap multiple expressions when they constitute a void value' do
      expect(wrap("def a\n1\nreturn 2\nend")).to eq "<def a\n<1>\nreturn <2>\nend>"
      expect(wrap("def a\nreturn 1\n2\nend")).to eq "<def a\nreturn <1>\n<2>\nend>"
    end

    it 'wraps nested expressions' do
      expect(wrap("A do\nB\nend")).to eq "<A do\n<B>\nend>"
    end

    it 'wraps multiple expressions on the same line' do
      expect(wrap("a;b")).to eq "a;<b>"
    end

    # many of these taken from http://en.wikibooks.org/wiki/Ruby_Programming/Syntax/Literals
    it 'wraps simple literals' do
      # should maybe also do %i[] and %I[] for symbols,
      # but that's only Ruby 2.0, so I'm ignoring it for now
      # (I expect it to handle them just fine)
      %w|123
         -123
         1_123
         -543
         123_456_789_123_456_789
         123.45
         1.2e-3
         0xaabb
         0377
         -0b1010
         0b001_001

         ?a
         ?\C-a
         ?\M-a
         ?\M-\C-a

         1..2
         1...2

         (true==true)..(1==2)

         true
         false
         nil
         self

         [1,2,3]
         [1,*a,*[2,3,4]]
         %w(1)
         %W(2)

         %x[ls]

         /abc/
         %r(abc)
         %r.abc.

         :abc
         :'abc'
         :"abc"
         :"a\#{1}"

         {1=>2}
         {a:1}
      |.each do |literal|
        actual   = wrap(literal)
        expected = "<#{literal}>"
        expect(actual).to eq(expected), "expected #{literal.inspect} to equal #{expected.inspect}, got #{actual.inspect}"
      end
    end

    it 'wraps macros' do
      # there is also __dir__, but it's only 2.0
      expect(wrap("__FILE__")).to eq "<__FILE__>"
      expect(wrap("__LINE__")).to eq "<__LINE__>"
      expect(wrap("__ENCODING__")).to eq "<__ENCODING__>"
      expect(wrap("defined? a")).to eq "<defined? a>"
    end

    it 'does not wrap alias, undef' do
      expect(wrap("alias tos to_s")).to eq "alias tos to_s"
      expect(wrap("undef tos")).to eq "undef tos"
    end

    it 'wraps syscalls, but not code interpolated into them' do
      expect(wrap("`a\nb`")).to eq "<`a\nb`>"
      expect(wrap("`a\n\#{1\n2\n3}b`")).to eq "<`a\n\#{1\n2\n3}b`>"
    end
  end

  describe 'variable lookups' do
    it 'wraps them' do
      expect(wrap('a')).to eq "<a>"
      expect(wrap("$a")).to eq "<$a>"
      expect(wrap("@a")).to eq "<@a>"
      expect(wrap("@@a")).to eq "<@@a>"
    end
  end

  describe 'method invocations' do
    it 'wraps the whole invocation with or without parens' do
      expect(wrap("a")).to eq "<a>"
      expect(wrap("a()")).to eq "<a()>"
      expect(wrap("a()")).to eq "<a()>"
    end

    it 'does not wrap arguments' do
      expect(wrap("a b")).to eq "<a b>"
      expect(wrap("a(b,c=1,*d,&e)")).to eq "<a(b,c=1,*d,&e)>"
    end

    it 'wraps blocks' do
      expect(wrap("a { }")).to eq "<a { }>"
      expect(wrap("a {\n}")).to eq "<a {\n}>"
      expect(wrap("a(b) {\n}")).to eq "<a(b) {\n}>"
    end

    it 'wraps method calls with an explicit receiver' do
      expect(wrap("1.mod(2)")).to eq "<1.mod(2)>"
      expect(wrap("1.mod 2")).to eq "<1.mod 2>"
    end

    it 'wraps operators calls' do
      expect(wrap("1+1")).to eq "<1+1>"
      expect(wrap("a.b+1")).to eq "<a.b+1>"
      expect(wrap("a.b - 1")).to eq "<a.b - 1>"
      expect(wrap("a.b -1")).to eq "<a.b -1>"
      expect(wrap("!1")).to eq "<!1>"
      expect(wrap("~1")).to eq "<~1>"
    end

    it 'wraps methods that end in bangs and questions' do
      expect(wrap("a.b!")).to eq "<a.b!>"
      expect(wrap("a.b?")).to eq "<a.b?>"
    end

    it 'wraps method invocations that span multiple lines' do
      expect(wrap("a\n.b\n.c")).to eq "<<<a>\n.b>\n.c>"
      expect(wrap("a\n.b{\n}")).to eq "<<a>\n.b{\n}>"
      expect(wrap("a\n.b{}")).to eq "<<a>\n.b{}>"
      expect(wrap("[*1..5]\n.map { |n| n * 2 }\n.take(2).\nsize")).to eq\
        "<<<<[*1..5]>\n.map { |n| n * 2 }>\n.take(2)>.\nsize>"
      expect(wrap("a = b\n.c\na")).to eq "<a = <b>\n.c>\n<a>"
    end

    it 'wraps args in method arguments when the method spans multiple lines' do
      expect(wrap("a 1,\n2")).to eq "<a <1>,\n2>"
    end

    it 'does not wrap splat args' do
      expect(wrap("a(\n*a\n)")).to eq "<a(\n*a\n)>"
      expect(wrap("a(\n*1..2\n)")).to eq "<a(\n*1..2\n)>"
    end

    it 'does not wrap hash args' do
      expect(wrap("a(b: 1,\nc: 2\n)")).to eq "<a(b: <1>,\nc: <2>\n)>"
    end
  end

  describe 'assignment' do
    it 'wraps entire simple assignment' do
      expect(wrap("a=1")).to eq "<a=1>"
      expect(wrap("a.b=1")).to eq "<a.b=1>"
      expect(wrap("A=1")).to eq "<A=1>"
      expect(wrap("::A=1")).to eq "<::A=1>"
      expect(wrap("A::B=1")).to eq "<A::B=1>"
      expect(wrap("@a=1")).to eq "<@a=1>"
      expect(wrap("@@a=1")).to eq "<@@a=1>"
      expect(wrap("$a=1")).to eq "<$a=1>"
    end

    it 'wraps multiple assignments' do
      expect(wrap("a,b=c")).to eq "<a,b=c>"
      expect(wrap("a,b=1,2")).to eq "<a,b=1,2>"
      expect(wrap("a,b.c=1,2")).to eq "<a,b.c=1,2>"
      expect(wrap("a,B=1,2")).to eq "<a,B=1,2>"
      expect(wrap("a,B::C=1,2")).to eq "<a,B::C=1,2>"
      expect(wrap("a,@b=1,2")).to eq "<a,@b=1,2>"
      expect(wrap("a,@@b=1,2")).to eq "<a,@@b=1,2>"
      expect(wrap("a,$b=1,2")).to eq "<a,$b=1,2>"
      expect(wrap("a, b = x.()")).to eq "<a, b = x.()>"
      expect(wrap("a, b = c\n.d,\ne\n.f")).to eq "<a, b = <<c>\n.d>,\n<e>\n.f>"
    end

    it 'wraps multiple assignment on each line' do
      expect(wrap("a,b=1,\n2")).to eq "<a,b=<1>,\n2>"
      expect(wrap("a,b=[1,2]\n.map(&:to_s)")).to eq "<a,b=<[1,2]>\n.map(&:to_s)>"
      expect(wrap("a,b=[1,\n2\n.even?\n]")).to eq "<a,b=[<1>,\n<<2>\n.even?>\n]>"
    end

    it 'wraps multiple assignment with splats' do
      expect(wrap("a,* =1,2,3")).to eq "<a,* =1,2,3>"
    end

    it 'wraps the array equivalent' do
      expect(wrap("a,* =[1,2,3]")).to eq "<a,* =[1,2,3]>"
      expect(wrap("a,* = [ 1,2,3 ] ")).to eq "<a,* = [ 1,2,3 ]> "
    end

    it 'wraps repeated assignments' do
      expect(wrap("a=b=1")).to eq "<a=b=1>"
      expect(wrap("a=b=\n1")).to eq "<a=b=\n1>"
      expect(wrap("a=\nb=\n1")).to eq "<a=\nb=\n1>"
    end

    it 'wraps operator assignment' do
      expect(wrap("a += 1")).to eq "<a += 1>"
      expect(wrap("a *= 1")).to eq "<a *= 1>"
      expect(wrap("a -= 1")).to eq "<a -= 1>"
      expect(wrap("a /= 1")).to eq "<a /= 1>"
      expect(wrap("a **= 1")).to eq "<a **= 1>"
      expect(wrap("a |= 1")).to eq "<a |= 1>"
      expect(wrap("a &= 1")).to eq "<a &= 1>"
      expect(wrap("a ||= 1")).to eq "<a ||= 1>"
      expect(wrap("a &&= 1")).to eq "<a &&= 1>"
      expect(wrap("a[1] = 2")).to eq "<a[1] = 2>"
      expect(wrap("a[1] ||= 2")).to eq "<a[1] ||= 2>"
      expect(wrap("@a  ||= 123")).to eq "<@a  ||= 123>"
      expect(wrap("$a  ||= 123")).to eq "<$a  ||= 123>"
      expect(wrap("@@a ||= 123")).to eq "<@@a ||= 123>"
      expect(wrap("B   ||= 123")).to eq "<B   ||= 123>"
      expect(wrap("@a  ||= begin\n123\nend")).to eq "<@a  ||= begin\n<123>\nend>"
      expect(wrap("$a  ||= begin\n123\nend")).to eq "<$a  ||= begin\n<123>\nend>"
      expect(wrap("@@a ||= begin\n123\nend")).to eq "<@@a ||= begin\n<123>\nend>"
      expect(wrap("B   ||= begin\n123\nend")).to eq "<B   ||= begin\n<123>\nend>"
    end

    it 'wraps assignments that span multiple lines' do
      # simple assignment
      expect(wrap("a={\n}")).to eq "<a={\n}>"
      expect(wrap("a, b = c,{\n}")).to eq "<a, b = <c>,{\n}>"
      expect(wrap("a.b={\n}")).to eq "<<a>.b={\n}>"
      expect(wrap("A={\n}")).to eq "<A={\n}>"
      expect(wrap("::A={\n}")).to eq "<::A={\n}>"
      expect(wrap("A::B={\n}")).to eq "<A::B={\n}>"
      expect(wrap("@a={\n}")).to eq "<@a={\n}>"
      expect(wrap("@@a={\n}")).to eq "<@@a={\n}>"
      expect(wrap("$a={\n}")).to eq "<$a={\n}>"

      # multiple assignment
      expect(wrap("a,b={\n}")).to eq "<a,b={\n}>"
      expect(wrap("a,b={\n},{\n}")).to eq "<a,b=<{\n}>,{\n}>"
      expect(wrap("a,b.c={\n},{\n}")).to eq "<a,b.c=<{\n}>,{\n}>"
      expect(wrap("a,B={\n},{\n}")).to eq "<a,B=<{\n}>,{\n}>"
      expect(wrap("a,B::C={\n},{\n}")).to eq "<a,B::C=<{\n}>,{\n}>"
      expect(wrap("a,@b={\n},{\n}")).to eq "<a,@b=<{\n}>,{\n}>"
      expect(wrap("a,@@b={\n},{\n}")).to eq "<a,@@b=<{\n}>,{\n}>"
      expect(wrap("a,$b={\n},{\n}")).to eq "<a,$b=<{\n}>,{\n}>"

      # repeated assignments
      expect(wrap("a=\nb={\n}")).to eq "<a=\nb={\n}>"

      # operator assignment
      expect(wrap("a +={\n}")).to eq "<a +={\n}>"
      expect(wrap("a *= {\n}")).to eq "<a *= {\n}>"
      expect(wrap("a -= {\n}")).to eq "<a -= {\n}>"
      expect(wrap("a /= {\n}")).to eq "<a /= {\n}>"
      expect(wrap("a **= {\n}")).to eq "<a **= {\n}>"
      expect(wrap("a |= {\n}")).to eq "<a |= {\n}>"
      expect(wrap("a &= {\n}")).to eq "<a &= {\n}>"
      expect(wrap("a ||= {\n}")).to eq "<a ||= {\n}>"
      expect(wrap("a &&= {\n}")).to eq "<a &&= {\n}>"
      expect(wrap("a[1] = {\n}")).to eq "<a[<1>] = {\n}>"
      expect(wrap("a[1]   ||= {\n}")).to eq "<a[1]   ||= {\n}>"
      expect(wrap("@a     ||= {\n}")).to eq "<@a     ||= {\n}>"
      expect(wrap("$a     ||= {\n}")).to eq "<$a     ||= {\n}>"
      expect(wrap("@@a    ||= {\n}")).to eq "<@@a    ||= {\n}>"
      expect(wrap("B      ||= {\n}")).to eq "<B      ||= {\n}>"
      expect(wrap("{}[:a] ||= {\n}")).to eq "<{}[:a] ||= {\n}>"

      # LHS with values in it on all the operator assignments
      expect(wrap("a.b  += {\n}")).to eq "<a.b  += {\n}>"
      expect(wrap("a.b  *= {\n}")).to eq "<a.b  *= {\n}>"
      expect(wrap("a.b  -= {\n}")).to eq "<a.b  -= {\n}>"
      expect(wrap("a.b  /= {\n}")).to eq "<a.b  /= {\n}>"
      expect(wrap("a.b **= {\n}")).to eq "<a.b **= {\n}>"
      expect(wrap("a.b  |= {\n}")).to eq "<a.b  |= {\n}>"
      expect(wrap("a.b  &= {\n}")).to eq "<a.b  &= {\n}>"
      expect(wrap("a.b &&= {\n}")).to eq "<a.b &&= {\n}>"
    end

    it 'wraps arguments in the assignment' do
      expect(wrap("a[1\n]=2")).to eq "<a[<1>\n]=2>"
      expect(wrap("a[1,\n2\n]=3")).to eq "<a[<1>,\n<2>\n]=3>"
    end
  end

  describe 'conditionals' do
    it 'wraps if/elsif/else/end, the whole thing, their conditionals, and their bodies' do
      expect(wrap("if 1\n2\nelsif 2\n3\nelsif 4\n5\nend")).to eq "<if <1>\n<2>\nelsif <2>\n<3>\nelsif <4>\n<5>\nend>" # multiple elsif
      expect(wrap("if 1\n2\nelsif 2\n3\nelse\n4\nend")).to eq "<if <1>\n<2>\nelsif <2>\n<3>\nelse\n<4>\nend>"         # elisf and else
      expect(wrap("if 1\n2\nelsif 3\n4\nend")).to eq "<if <1>\n<2>\nelsif <3>\n<4>\nend>"                             # elsif only
      expect(wrap("if 1\n2\nelse\n2\nend")).to eq "<if <1>\n<2>\nelse\n<2>\nend>"                                     # else only
      expect(wrap("if 1\n2\nend")).to eq "<if <1>\n<2>\nend>"                                                         # if only

      # same as above, but with then
      expect(wrap("if 1 then\n2\nelsif 2 then\n3\nelsif 4 then\n5\nend")).to eq "<if <1> then\n<2>\nelsif <2> then\n<3>\nelsif <4> then\n<5>\nend>"
      expect(wrap("if 1 then\n2\nelsif 2 then\n3\nelse\n4\nend")).to eq "<if <1> then\n<2>\nelsif <2> then\n<3>\nelse\n<4>\nend>"
      expect(wrap("if 1 then\n2\nelsif 3 then\n4\nend")).to eq "<if <1> then\n<2>\nelsif <3> then\n<4>\nend>"
      expect(wrap("if 1 then\n2\nelse\n2\nend")).to eq "<if <1> then\n<2>\nelse\n<2>\nend>"
      expect(wrap("if 1 then\n2\nend")).to eq "<if <1> then\n<2>\nend>"

      # inline
      expect(wrap("1 if 2")).to eq "<1 if 2>"
    end

    it 'ignores conditionals that are implicit regexes' do
      expect(wrap("if /a/\n1\nend")).to eq "<if /a/\n<1>\nend>"
    end

    it 'wraps ternaries' do
      expect(wrap("1 ? 2 : 3")).to eq "<1 ? 2 : 3>"
      expect(wrap("1\\\n?\\\n2\\\n:\\\n3")).to eq "<<1>\\\n?\\\n<2>\\\n:\\\n3>"
    end

    it 'wraps "unless" statements' do
      expect(wrap("unless 1\n2\nelse\n3\nend")).to eq "<unless <1>\n<2>\nelse\n<3>\nend>"
      expect(wrap("unless 1\n2\nend")).to eq "<unless <1>\n<2>\nend>"
      expect(wrap("unless 1 then\n2\nelse\n3\nend")).to eq "<unless <1> then\n<2>\nelse\n<3>\nend>"
      expect(wrap("unless 1 then\n2\nend")).to eq "<unless <1> then\n<2>\nend>"
      expect(wrap("1 unless 2")).to eq "<1 unless 2>"
    end

    it 'wraps case statements, and the value they are initialized with, but not the conditionals' do
      expect(wrap("case 1\nwhen 2\n3\nwhen 4, 5\nelse\n6\nend")).to eq "<case <1>\nwhen 2\n<3>\nwhen 4, 5\nelse\n<6>\nend>"
      expect(wrap("case 1\nwhen 2\nend")).to eq "<case <1>\nwhen 2\nend>"
      expect(wrap("case\nwhen 2\nend")).to eq "<case\nwhen 2\nend>"
      expect(wrap("case\nwhen 2, 3\n4\n5\nend")).to eq "<case\nwhen 2, 3\n<4>\n<5>\nend>"

      expect(wrap("case 1\nwhen 2 then\n3\nwhen 4, 5 then\nelse\n6\nend")).to eq "<case <1>\nwhen 2 then\n<3>\nwhen 4, 5 then\nelse\n<6>\nend>"
      expect(wrap("case 1\nwhen 2 then\nend")).to eq "<case <1>\nwhen 2 then\nend>"
      expect(wrap("case\nwhen 2 then\nend")).to eq "<case\nwhen 2 then\nend>"
      expect(wrap("case\nwhen 2, 3 then\n4\n5\nend")).to eq "<case\nwhen 2, 3 then\n<4>\n<5>\nend>"
    end

    it 'does not wrap if the last value in any portion is a void value expression' do
      expect(wrap("def a\nif true\nreturn 1\nend\nend")).to eq "<def a\nif <true>\nreturn <1>\nend\nend>"
      expect(wrap("def a\nif true\n1\nelse\nreturn 2\nend\nend")).to eq "<def a\nif <true>\n<1>\nelse\nreturn <2>\nend\nend>"
      expect(wrap("def a\nif true\n1\nelsif true\n2\nelse\nreturn 3\nend\nend")).to eq "<def a\nif <true>\n<1>\nelsif <true>\n<2>\nelse\nreturn <3>\nend\nend>"
      expect(wrap("def a\nif true\nif true\nreturn 1\nend\nend\nend")).to eq "<def a\nif <true>\nif <true>\nreturn <1>\nend\nend\nend>"
      expect(wrap("def a\nunless true\nreturn 1\nend\nend")).to eq "<def a\nunless <true>\nreturn <1>\nend\nend>"
      expect(wrap("def a\nunless true\n1\nelse\nreturn 2\nend\nend")).to eq "<def a\nunless <true>\n<1>\nelse\nreturn <2>\nend\nend>"
      expect(wrap("def a\ntrue ?\n(return 1) :\n2\nend")).to eq "<def a\n<true> ?\n(return <1>) :\n<2>\nend>"
      expect(wrap("def a\ntrue ?\n1 :\n(return 2)\nend")).to eq "<def a\n<true> ?\n<1> :\n(return <2>)\nend>"
    end

    # not sure if I actually want this, or if it's just easier b/c it falls out of the current implementation
    it 'wraps the conditional from an inline if, when it cannot wrap the entire if' do
      expect(wrap("def a\nreturn if 1\nend")).to eq "<def a\nreturn if <1>\nend>"
    end

    it 'does not wrap &&, and, ||, or, not' do
      expect(wrap("1\\\n&& 2")).to eq "<<1>\\\n&& 2>"
      expect(wrap("1\\\nand 2")).to eq "<<1>\\\nand 2>"
      expect(wrap("1\\\n|| 2")).to eq "<<1>\\\n|| 2>"
      expect(wrap("1\\\nor 2")).to eq "<<1>\\\nor 2>"
      expect(wrap("not\\\n1")).to eq "<not\\\n1>"
      expect(wrap("!\\\n1")).to eq "<!\\\n1>"
    end
  end

  describe 'loops' do
    it 'wraps the until condition and body' do
      expect(wrap("until 1\n2\nend")).to eq "<until <1>\n<2>\nend>"
      expect(wrap("1 until 2")).to eq "<1 until 2>"
      expect(wrap("begin\n1\nend until true")).to eq "<begin\n<1>\nend until true>"
    end
    it 'wraps the while condition and body' do
      expect(wrap("while 1\n2\nend")).to eq "<while <1>\n<2>\nend>"
      expect(wrap("1 while 2")).to eq "<1 while 2>"
      expect(wrap("begin\n1\nend while true")).to eq "<begin\n<1>\nend while true>"
    end
    it 'wraps for/in loops collections and bodies' do
      expect(wrap("for a in range;1;end")).to eq "<for a in range;1;end>"
      expect(wrap("for a in range\n1\nend")).to eq "<for a in <range>\n<1>\nend>"
      expect(wrap("for a in range do\n1\nend")).to eq "<for a in <range> do\n<1>\nend>"
      expect(wrap("for a,b in whatev\n1\nend")).to eq "<for a,b in <whatev>\n<1>\nend>"
      # this one just isn't worth it for now, too edge and I'm fucking tired
      # wrap("for char in <<HERE.each_char\nabc\nHERE\nputs char\nend").should ==
      #   "<for char in <<<HERE.each_char>\nabc\nHERE\n<puts char>\nend>"
    end
    it 'does not wrap redo' do
      expect(wrap("loop do\nredo\nend")).to eq "<loop do\nredo\nend>"
    end
    it 'wraps the value of break' do
      expect(wrap("loop do\nbreak 1\nend")).to eq "<loop do\nbreak <1>\nend>"
    end
    it 'wraps the value of next' do
      expect(wrap("loop do\nnext 10\nend")).to eq "<loop do\nnext <10>\nend>"
    end
  end

  describe 'constant access' do
    it 'wraps simple constant access' do
      expect(wrap("A")).to eq "<A>"
    end

    it 'wraps namespaced constant access' do
      expect(wrap("::A")).to eq "<::A>"
      expect(wrap("A::B")).to eq "<A::B>"
    end
  end

  describe 'hash literals' do
    it 'wraps the whole hash and values that are on their own lines' do
      expect(wrap("{}")).to eq "<{}>"
      expect(wrap("{\n1 => 2}")).to eq "<{\n1 => 2}>"
      expect(wrap("{\n1 => 2,\n:abc => 3,\ndef: 4\n}")).to eq "<{\n1 => <2>,\n:abc => <3>,\ndef: <4>\n}>"
    end
  end

  describe 'array literals' do
    it 'wraps the array and each element that is on its own line' do
      expect(wrap("[1]")).to eq "<[1]>"
      expect(wrap("[1,\n2,\n]")).to eq "<[<1>,\n<2>,\n]>"
      expect(wrap("[1, 2,\n]")).to eq "<[1, <2>,\n]>"
    end

    it 'does not wrap magic arrays' do
      expect(wrap("%w[\n1\n]")).to eq "<%w[\n1\n]>"
    end

    it 'does not wrap splat elements' do
      expect(wrap("[1,\n*2..3,\n4\n]")).to eq "<[<1>,\n*2..3,\n<4>\n]>"
    end
  end

  describe 'regex literals' do
    it 'wraps regexes' do
      expect(wrap("/a/")).to eq "</a/>"
      expect(wrap("/(?<a>x)/")).to eq "</(?<a>x)/>"
    end

    it 'wraps regexes with %r' do
      expect(wrap("%r(a)")).to eq "<%r(a)>"
      expect(wrap("%r'a'")).to eq "<%r'a'>"
    end

    it 'wraps regexes that span mulitple lines' do
      expect(wrap("/a\nb/")).to eq "</a\nb/>"
      expect(wrap("/a\nb/i")).to eq "</a\nb/i>"
    end

    # eventually it would be nice if it wraped the interpolated portion,
    # when the end of the line was not back inside the regexp
    it 'wraps regexes with interpolation, but not the interpolated portion' do
      expect(wrap("/a\#{1}/")).to eq "</a\#{1}/>"
      expect(wrap("/a\n\#{1}\nb/")).to eq "</a\n\#{1}\nb/>"
      expect(wrap("/a\n\#{1\n}b/")).to eq "</a\n\#{1\n}b/>"
    end
  end

  describe 'string literals (except heredocs)' do
    it 'wraps single and double quoted strings' do
      expect(wrap("'a'")).to eq "<'a'>"
      expect(wrap('"a"')).to eq '<"a">'
    end

    it 'wraps strings with %, %Q, and %q' do
      expect(wrap("%'a'")).to eq "<%'a'>"
      expect(wrap("%q'a'")).to eq "<%q'a'>"
      expect(wrap("%Q'a'")).to eq "<%Q'a'>"
    end

    it 'wraps strings that span mulitple lines' do
      expect(wrap("'a\nb'")).to eq "<'a\nb'>"
      expect(wrap(%'"a\nb"')).to eq %'<"a\nb">'
    end

    # eventually it would be nice if it wraped the interpolated portion,
    # when the end of the line was not back inside the string
    it 'wraps strings with interpolation, but not the interpolated portion' do
      expect(wrap('"a#{1}"')).to eq '<"a#{1}">'
      expect(wrap(%'"a\n\#{1}\nb"')).to eq %'<"a\n\#{1}\nb">'
      expect(wrap(%'"a\n\#{1\n}b"')).to eq %'<"a\n\#{1\n}b">'
    end

    it 'wraps %, %q, %Q' do
      expect(wrap('%(A)')).to eq '<%(A)>'
      expect(wrap('%.A.')).to eq '<%.A.>'
      expect(wrap('%q(A)')).to eq '<%q(A)>'
      expect(wrap('%q.A.')).to eq '<%q.A.>'
      expect(wrap('%Q(A)')).to eq '<%Q(A)>'
      expect(wrap('%Q.A.')).to eq '<%Q.A.>'
    end

    it 'wraps heredocs with call defined on them (edge cases on edge cases *sigh*)' do
      expect(heredoc_wrap "<<HERE.()\na\nHERE")
        .to eq "[{<<HERE.()}]\na\nHERE"
    end
  end

  describe 'heredocs' do
    it 'wraps heredocs on their first line' do
      expect(heredoc_wrap "<<A\nA").to eq "[{<<A}]\nA"
      expect(heredoc_wrap "<<A\n123\nA").to eq "[{<<A}]\n123\nA"
      expect(heredoc_wrap "<<-A\nA").to eq "[{<<-A}]\nA"
      expect(heredoc_wrap "<<-A\n123\nA").to eq "[{<<-A}]\n123\nA"
      expect(heredoc_wrap "1\n<<A\nA").to eq "[{1}\n{<<A}]\nA"
      expect(heredoc_wrap "<<A + <<B\n1\nA\n2\nB").to eq "[{<<A + <<B}]\n1\nA\n2\nB"
      expect(heredoc_wrap "<<A\n1\nA\n<<B\n2\nB").to eq "[{<<A}\n1\nA\n{<<B}]\n2\nB"
      expect(heredoc_wrap "puts <<A\nA\nputs <<B\nB").to eq "[{puts <<A}\nA\n{puts <<B}]\nB"
    end

    it "wraps methods that wrap heredocs, even whent hey don't have parentheses" do
      expect(heredoc_wrap "a(<<HERE)\nHERE").to eq "[{a(<<HERE)}]\nHERE"
      expect(heredoc_wrap "a <<HERE\nHERE").to eq "[{a <<HERE}]\nHERE"
      expect(heredoc_wrap "a 1, <<HERE\nHERE").to eq "[{a 1, <<HERE}]\nHERE"
      expect(heredoc_wrap "a.b 1, 2, <<HERE1, <<-HERE2 \nHERE1\n HERE2").to eq\
          "[{a.b 1, 2, <<HERE1, <<-HERE2}] \nHERE1\n HERE2"
      expect(heredoc_wrap "a.b 1,\n2,\n<<HERE\nHERE").to eq "[{a.b {1},\n{2},\n<<HERE}]\nHERE"
    end

    it "wraps assignments whose value is a heredoc" do
      expect(heredoc_wrap "a=<<A\nA").to eq "[{a=<<A}]\nA"
      expect(heredoc_wrap "a,b=<<A,<<B\nA\nB").to eq "[{a,b=<<A,<<B}]\nA\nB"
      expect(heredoc_wrap "a,b=1,<<B\nB").to eq "[{a,b=1,<<B}]\nB"
      expect(heredoc_wrap "a,b=<<A,1\nA").to eq "[{a,b=<<A,1}]\nA"
    end

    it 'wraps methods tacked onto the end of heredocs' do
      expect(heredoc_wrap "<<A.size\nA").to eq "[{<<A.size}]\nA"
      expect(heredoc_wrap "<<A.size 1\nA").to eq "[{<<A.size 1}]\nA"
      expect(heredoc_wrap "<<A.size(1)\nA").to eq "[{<<A.size(1)}]\nA"
      expect(heredoc_wrap "<<A.whatever <<B\nA\nB").to eq "[{<<A.whatever <<B}]\nA\nB"
      expect(heredoc_wrap "<<A.whatever(<<B)\nA\nB").to eq "[{<<A.whatever(<<B)}]\nA\nB"
      expect(heredoc_wrap "<<A.size()\nA").to eq "[{<<A.size()}]\nA"
    end
  end

  # raises can be safely ignored, they're just method invocations
  describe 'begin/rescue/else/ensure/end blocks' do
    it 'wraps begin/rescue/else/ensure/end blocks' do
      expect(wrap("begin\nrescue\nelse\nensure\nend")).to eq "<begin\nrescue\nelse\nensure\nend>"
      expect(wrap("begin\nrescue e\ne\nend")).to eq "<begin\nrescue e\n<e>\nend>"
      expect(wrap("begin\nrescue Exception\n$!\nend")).to eq "<begin\nrescue Exception\n<$!>\nend>"
    end
    it 'wraps inline rescues' do
      pending "can't figure out how to identify these as different from begin/rescue/end"
      expect(wrap("1 rescue nil")).to eq "<1 rescue nil>"
    end
    it 'wraps the bodies' do
      expect(wrap("begin\n1\nrescue\n2\nelse\n3\nensure\n4\nend")).to eq\
        "<begin\n<1>\nrescue\n<2>\nelse\n<3>\nensure\n<4>\nend>"
    end
    it 'wraps bodies with various pieces missing' do
      expect(wrap("begin\n1\nrescue\n2\nelse\n3\nensure\n4\nend")).to eq "<begin\n<1>\nrescue\n<2>\nelse\n<3>\nensure\n<4>\nend>"
      expect(wrap("begin\n1\nrescue\n2\nelse\n3\nend")).to eq "<begin\n<1>\nrescue\n<2>\nelse\n<3>\nend>"
      expect(wrap("begin\n1\nrescue\n2\nend")).to eq "<begin\n<1>\nrescue\n<2>\nend>"
      expect(wrap("begin\n1\nend")).to eq "<begin\n<1>\nend>"
      expect(wrap("begin\nend")).to eq "<begin\nend>"
      expect(wrap("begin\n1\nensure\n2\nend")).to eq "<begin\n<1>\nensure\n<2>\nend>"
    end
    it 'does not wrap arguments to rescue' do
      expect(wrap("begin\nrescue\nrescue => a\nrescue SyntaxError\nrescue Exception => a\nelse\nensure\nend")).to eq\
            "<begin\nrescue\nrescue => a\nrescue SyntaxError\nrescue Exception => a\nelse\nensure\nend>"
    end
    it 'does not wrap retry' do
      # in this case, it could wrap the retry
      # but I don't know how to tell the difference between this and
      # "loop { begin; retry; end }" so w/e
      expect(wrap("begin\nrescue\nretry\nend")).to eq "<begin\nrescue\nretry\nend>"
    end
  end

  # eventually, don't wrap these b/c they're spammy, but can be annoying since they can be accidentally wraped
  # by e.g. a begin/end
  # ignoring public/private/protected for now, b/c they're just methods, not keywords
  describe 'class definitions' do
    it 'does not wrap the class definition, does wrap the body' do
      expect(wrap("class A\n1\nend")).to eq "class A\n<1>\nend"
    end

    it 'does not wrap the superclass definition' do
      expect(wrap("class A < B\nend")).to eq "class A < B\nend"
    end

    it 'wraps the rescue body' do
      expect(wrap("class A < B\n1\nrescue\n2\nend")).to eq "class A < B\n<1>\nrescue\n<2>\nend"
    end

    it 'does not wrap the singleton class' do
      expect(wrap("class << self\n end")).to eq "class << self\n end"
    end
  end

  # eventually, don't wrap these b/c they're spammy, but can be annoying since they can be accidentally wraped
  # by e.g. a begin/end
  # ignoring public/private/protected for now, b/c they're just methods, not keywords
  describe 'module definitions' do
    it 'does not wrap the definition, does wrap the body' do
      expect(wrap("module A\n1\nend")).to eq "module A\n<1>\nend"
    end
    it 'wraps the rescue portion' do
      expect(wrap("module A\n1\nrescue\n2\nend")).to eq "module A\n<1>\nrescue\n<2>\nend"
    end
  end

  describe 'method definitions' do
    it 'does wraps the definition, but not the arguments' do
      expect(wrap("def a(b,c=1,*d,&e)\nend")).to eq "<def a(b,c=1,*d,&e)\nend>"
    end

    it 'wraps the the body' do
      expect(wrap("def a\n1\nend")).to eq "<def a\n<1>\nend>"
      expect(wrap("def a()\n1\nend")).to eq "<def a()\n<1>\nend>"
      expect(wrap("def a\n1\n2\nend")).to eq "<def a\n<1>\n<2>\nend>"
    end

    it 'wraps singleton method definitions' do
      expect(wrap("def a.b\n1\nend")).to eq "<def a.b\n<1>\nend>"
      expect(wrap("def a.b()\n1\nend")).to eq "<def a.b()\n<1>\nend>"
      expect(wrap("def a.b\n1\n2\nend")).to eq "<def a.b\n<1>\n<2>\nend>" # <-- seems redundant, but this was a regression
    end

    it 'wraps calls to yield' do
      expect(wrap("def a\nyield\nend")).to eq "<def a\n<yield>\nend>"
    end

    it 'wraps calls to super' do
      expect(wrap("def a\nsuper\nend")).to eq "<def a\n<super>\nend>"
      expect(wrap("def a\nsuper 1\nend")).to eq "<def a\n<super 1>\nend>"
    end

    it 'wraps the bodies of returns' do
      expect(wrap("def a\nreturn 1\nend")).to eq "<def a\nreturn <1>\nend>"
    end

    it 'wraps the rescue and ensure portion' do
      expect(wrap("def a\n1\nrescue\n2\nend")).to eq "<def a\n<1>\nrescue\n<2>\nend>"
      expect(wrap("def a\n1\nrescue\n2\nensure\n3\nend")).to eq "<def a\n<1>\nrescue\n<2>\nensure\n<3>\nend>"
      expect(wrap("def a\n1\nensure\n2\nend")).to eq "<def a\n<1>\nensure\n<2>\nend>"
    end
  end

  describe 'lambdas' do
    it 'wraps the lambda' do
      expect(wrap("lambda { }")).to eq "<lambda { }>"
      expect(wrap("-> { }")).to eq "<-> { }>"
      expect(wrap("-> a, b { }")).to eq "<-> a, b { }>"
      expect(wrap("-> {\n1\n}")).to eq "<-> {\n<1>\n}>"
      expect(wrap("-> * { }")).to eq "<-> * { }>"
    end

    it 'wraps the full invocation' do
      expect(wrap("lambda { }.()")).to eq "<lambda { }.()>"
      expect(wrap("-> { }.()")).to eq "<-> { }.()>"
      expect(wrap("-> a, b {\n1\n}.(1,\n2)")).to eq "<-> a, b {\n<1>\n}.(<1>,\n2)>"
      expect(wrap("-> a, b { }.call(1, 2)")).to eq "<-> a, b { }.call(1, 2)>"
      expect(wrap("-> * { }.()")).to eq "<-> * { }.()>"
    end
  end

  describe 'BEGIN/END' do
    # not implemented b/c we cannot wrap around these either.
    # So what does it mean to wrap around?
    # maybe this?
    #   1
    #   BEGIN {}
    #   2
    #   END {}
    #   3
    #
    # becomes
    #   BEGIN {}
    #   END {}
    #   [<1>
    #   <2>
    #   <3>]
    #
    # idk, but then we also need to deal with the fact that we're changing result of __LINE__
    # which we could do with some meta, just replacing it with the literal when we parse it
    # but still, moving this out of here will be really annoying, and no one is going to use it, so fuck it
    it 'does not record them', not_implemented: true do
      pending 'not implemented, and probably never will be'
      expect(wrap("BEGIN {}")).to eq "BEGIN {}"
      expect(wrap("END {}")).to eq "END {}"
      expect(wrap("BEGIN {\n123\n}")).to eq "BEGIN {\n<123>\n}"
      expect(wrap("END {\n123\n}")).to eq "END {\n<123>\n}"
    end
  end
end
