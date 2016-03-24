------------------------------------------------------------------------------
--                                                                          --
--                               GNATcoverage                               --
--                                                                          --
--                     Copyright (C) 2009-2012, AdaCore                     --
--                                                                          --
-- GNATcoverage is free software; you can redistribute it and/or modify it  --
-- under terms of the GNU General Public License as published by the  Free  --
-- Software  Foundation;  either version 3,  or (at your option) any later  --
-- version. This software is distributed in the hope that it will be useful --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Coverage;

package Annotations.Xml is

   --  This package provides support to output coverage results in XML format.
   --  To make this easily useable by an external tool, there is only one
   --  single entry for the XML output. To avoid to make this file a monster,
   --  it is broken down into sub-units by the use of the Xinclude standard.
   --
   --  The following files are generated:
   --
   --  * an index file, named index.xml;
   --  * one file per compilation unit, named after the corresponding source
   --  file with a suffix ".xml".
   --
   --  The following sections will describe each file type. The following
   --  convention will be used to denotate possible values for attributes:
   --
   --  * COVERAGE_KIND: can be either 'insn', 'branch', 'stmt',
   --             'stmt+decision', 'stmt+mcdc'.
   --  * COVERAGE: can be either '+' (total coverage for the chosen coverage
   --              criteria), '-' (null coverage), '!' (partial coverage) or
   --              '.' (no code for this line).
   --  * OBJ_COVERAGE: can be either '+' (covered), '>' (branch taken),
   --              'V' (branch fallthrough) and '-' (not covered).
   --  * TEXT: any text into quotes. Mostly used for source lines.
   --  * ADDRESS: an hexademical number, C convention. e.g. 0xdeadbeef.
   --  * NUM: a decimal number.
   --
   --
   --  Index :
   --  -------
   --
   --
   --  Description :
   --  .............
   --
   --  The index file contains one root element:
   --
   --  <coverage_report>: it contains the following attributes:
   --
   --    coverage_level: COVERAGE_KIND; type of coverage operation that has
   --                    been recorded in this report.
   --
   --  <coverage_report> has the following child elements:
   --
   --    <coverage_info>: information related to the coverage operation
   --       (e.g. list of trace files).
   --       This should contain a list of child elements <xi:include>
   --       with the following attributes:
   --
   --       parse : set to "xml"
   --       href  : path to the file that contains a trace info file.
   --
   --
   --    <sources>: List of annotated source files. This should contain a list
   --       of child elements <xi:include> with the following attributes:
   --
   --
   --       parse : set to "xml"
   --       href  : path to the file that contains an annotated source
   --               report.
   --
   --  Example:
   --  ........
   --
   --  Consider a program hello.adb that contains a package
   --  pack.adb.  Suppose that two runs have been done for this program,
   --  generating two trace files trace1/hello.trace and
   --  trace2/hello.trace. Its branch coverage report would look like:
   --
   --  <?xml version="1.0" ?>
   --  <document xmlns:xi="http://www.w3.org/2001/XInclude">
   --   <coverage_report coverage_level="stmt">
   --
   --    <coverage_info>
   --      <xi:include parse="xml" href="trace.xml"/>
   --    </coverage_info>
   --
   --    <sources>
   --      <xi:include parse="xml" href="hello.adb.xml"/>
   --      <xi:include parse="xml" href="pack.adb.xml"/>
   --    </sources>
   --
   --   </coverage_report>
   --
   --  </document>
   --
   --
   --  Trace info :
   --  ------------
   --
   --
   --  Description:
   --  ............
   --
   --  The trace info contains one root element:
   --
   --  <traces>: it represents the list of trace files given to the coverage
   --     tool. It should contain a list of the following child elements:
   --
   --     <trace>: represents a given trace file. It shall have the following
   --        attributes:
   --
   --        filename : name of the trace file on the host file system.
   --        program  : name of the executable program on the host file system.
   --        date     : date of the run that generated the trace file.
   --        tag      : trace file tag.
   --
   --  Example:
   --  ........
   --
   --  <?xml version="1.0" ?>
   --  <traces>
   --    <trace filename="explore1.trace"
   --           program="explore"
   --           date="2009-06-18 18:19:17"
   --           tag="first run"/>
   --
   --    <trace filename="explore2.trace"
   --           program="explore"
   --           date="2009-06-18 18:22:32"
   --           tag="second run"/>
   --  </traces>
   --
   --
   --  Annotated compilation unit :
   --  ----------------------------
   --
   --  Some preliminary discussion first. A priori, there are two ways to
   --  organize the coverage information in an annotated source:
   --  * source-based view: iterating on lines; for each line, coverage
   --    items (instruction/statement/decision...) are included.
   --  * coverage-based view: iterating on coverage items; for each item, line
   --    information is given.
   --
   --  Both approaches have their utility; the source-based view makes it easy
   --  to generate source-based html reports (similar to the one generated by
   --  --annotate=html+); the coverage-based view, closer to what the SCOs
   --  provide, can more easily express the structure of decisions (the
   --  condition that they contain, and which values they have taken).
   --  The limitation of one approach is actually the asset of the other: a
   --  coverage-centric report would make it hard for an external to rebuild
   --  the source out of it; at the contrary, a source-centric report would
   --  make it painful to aggregates informations about a particular decision.
   --
   --  The xml format proposed here tries to take the advantages of both
   --  worlds.  Instead of starting from lines or from coverage item and
   --  trying to make one a child of the other, this format is based on
   --  an element that pairs the two together. That is to say, instead of
   --  having:
   --
   --  [...]
   --  <line num="1" src="      A := 1;">
   --     <statement_start coverage="+"/>
   --  </line>
   --  [...]
   --
   --  or something like:
   --
   --  [...]
   --  <statement line_begin="1" line_end="2" coverage="+" src="A := 1;"/>
   --  [...]
   --
   --  we will have:
   --
   --  [...]
   --  <src_mapping>
   --    <src>
   --      <line num="1" src="      A := 1;"/>
   --    </src>
   --
   --    <statement coverage="+"/>
   --  </src_mapping>
   --  [...]
   --
   --  What we call here a "src mapping" is the relation between a set of
   --  line in the source code and a tree of coverage items.
   --
   --  One property that we would then be able to inforce is: monotonic
   --  variation of src lines. More clearly: if a src mapping has a child
   --  element src that contains line 12 and 13, the src mapping before it
   --  will contain line 11, the src mapping after it will contain line 14.
   --  This will ease the  generation of a human-readable (say, HTML) report
   --  based on source lines; remember, that was one of the good properties
   --  of the line-based approach.
   --
   --  Now, let us have a look to the details...
   --
   --  Description :
   --  .............
   --
   --  The annotated compilation unit contains one root element:
   --
   --  <source>: it contains the following attributes:
   --
   --     file           : TEXT; path to the source file.
   --     coverage_level : COVERAGE_KIND; type of coverage operation that has
   --                      been recorded in this report.
   --
   --  It may contain a list of the followind child elements:
   --
   --     <src_mapping>: node that associate a fraction of source code to
   --        coverage item. It may have the following attribute:
   --
   --        coverage: aggregated coverage information for this fraction of
   --                  source code.
   --
   --        It should contains the following mandatory child element...
   --
   --        <src>: node that contains a list of contiguous source lines of
   --               code.
   --           It contains a list of the following child elements:
   --
   --           <line/>: represents a line of source code. It shall have the
   --                    following attributes:
   --
   --              num : NUM; line number in source code.
   --              src : TEXT; copy of the line as it appears in the source
   --                    code.
   --
   --
   --
   --       ...and <src_mapping> may also contain a list of child elements
   --       that represents coverage items. These coverage items can be
   --       instruction sets, statements or decision. Here are the
   --       corresponding child elements:
   --
   --        <message/>: represents an error message or a warning attached to
   --        this line. It can have the following attributes:
   --
   --           kind    : warning or error
   --           SCO     : Id of the SCO to which this message is attached
   --           message : actual content of the message
   --
   --        <instruction_set>: node that represents a set of instructions.
   --        It should contain the following attribute:
   --
   --           coverage : COVERAGE; coverage information associated to this
   --           instruction set.
   --
   --           The element <instruction_set> may also contain a list of the
   --           following child elements:
   --
   --              <instruction_block>: coverage information associated to
   --                 contiguous instructions. It has the following attributes:
   --
   --                 name     : TEXT; name of the symbol. e.g. "main",
   --                            "_ada_p".
   --                 offset   : ADDRESS; offset from the symbol.
   --                 coverage : COVERAGE; how this instruction block
   --                            is covered.
   --
   --                 The element <instruction_block> may contain a list of the
   --                 following child elements:
   --
   --                    <instruction/>: coverage information associated to
   --                       a given instruction. it contains the following
   --                       attributes:
   --
   --                       address  : ADDRESS;
   --                       coverage : OBJ_COVERAGE; how this instruction has
   --                          been covered.
   --                       assembly : TEXT; assembly code for this
   --                          instruction.
   --
   --
   --        <statement>: represents a statement. It may contain the
   --           following attributes:
   --
   --           coverage : COVERAGE; coverage information associated to a
   --              statement.
   --           id : NUM; identifier of the associated source coverage
   --              obligation
   --           text : TEXT; short extract of code used that can be used to
   --              identify the corresponding source entity.
   --
   --
   --           The element <statement> may contain one child element:
   --
   --              <src>: source information associated to this statement. If
   --                 no src node is given, then the src of the upper node is
   --                 "inherited".
   --                 Same thing for conditions, decisions, statements...
   --
   --              The element <src> may contain a list of the following child
   --              elements:
   --
   --                 <line/>: represents a line of source code. It may have
   --                    the following attributes:
   --
   --                    num          : NUM; line number in source code.
   --                    column_begin : NUM; column number for the beginning
   --                                   of the coverage item we are
   --                                   considering.
   --                    column_end   : NUM; column number for the end of the
   --                                   coverage item we are considering.
   --                    src          : TEXT; copy of the line as it appears
   --                                   in the source code.
   --
   --        <decision>: represents a decision. It may contain the following
   --           attributes:
   --
   --           coverage : COVERAGE; coverage information associated to a
   --              statement.
   --           id : NUM; identifier of the associated source coverage
   --              obligation
   --           text : TEXT; short extract of code used that can be used to
   --              identify the corresponding source entity.
   --
   --           The element <decision> may also contain the following child
   --           elements:
   --
   --              <src>: same as its homonym in <statement>; see above.
   --
   --              <condition>: represents a condition. It may contains the
   --              following attributes:
   --
   --                 coverage : COVERAGE; coverage information associated to a
   --                    statement.
   --                 id : NUM; identifier of the associated source coverage
   --                    obligation
   --                 text : TEXT; short extract of code used that can be
   --                    used to identify the corresponding source entity.
   --
   --              ...and the following child elements:
   --
   --                 <src>: same as its homonym in <statement>; see above.
   --
   --  Example:
   --  ........
   --
   --  Consider the following Ada function, defined in a file named test.adb:
   --
   --  --  file test.adb
   --
   --  with Pack;
   --
   --  function Test
   --    (A : Boolean;
   --     B : Boolean;
   --     C : Boolean;
   --     D : Boolean) return Integer is
   --  begin
   --     if A and then (B or else F (C
   --                                 and then D))
   --        return 12;
   --     end if;
   --     Pack.Func; return 13;
   --  end Test;
   --
   --
   --  This coverage of this file can be represented by the report shown below.
   --  Notice in particular:
   --  * how the two statements at line 14 can be represented;
   --  * how the coverage of the two decisions on line 11-12 are represented.
   --
   --  <?xml version="1.0" ?>
   --  <source file="test.adb" coverage_level="stmt+mcdc">
   --     <src_mapping coverage=".">
   --        <src>
   --           <line num="1" src="--  file test.adb"/>
   --           <line num="2" src=""/>
   --           <line num="3" src="with Pack;"/>
   --           <line num="4" src=""/>
   --           <line num="5" src="function Test"/>
   --           <line num="6" src="  (A : Boolean;"/>
   --           <line num="7" src="   B : Boolean;"/>
   --           <line num="8" src="   C : Boolean;"/>
   --           <line num="9" src="   D : Boolean) return Integer is"/>
   --           <line num="10" src="begin"/>
   --        </src>
   --     <src_mapping>
   --
   --     <src_mapping coverage="!">
   --        <src>
   --           <line num="11" src="   if A and then (B or else F (C"/>
   --           # This src_mapping could also contain the line that follows;
   --           # after all, the two decisions that it contains end on line
   --           # 12. It does not matter much at this point. The important
   --           # property is that every coverage entity that starts on line
   --           # 11 is defined in this src_mapping.
   --        </src>
   --
   --        <decision id="1" text="A and th..." coverage="!">
   --           <src>
   --             <line num="11" src="   if A and then (B or else F (C"/>
   --             <line num="12"
   --                   src="                               and then D))"/>
   --           </src>
   --
   --
   --           <condition id="2" text="A" coverage="+">
   --              <src>
   --                 <line num="11"
   --                       column_begin="6"
   --                       column_end="7"
   --                       src="A"/>
   --              </src>
   --           </condition>
   --
   --           <condition id="3" text="B" coverage="-">
   --              <src>
   --                 <line num="11"
   --                       column_begin="18"
   --                       column_end="19"
   --                       src="B"/>
   --              </src>
   --
   --           </condition>
   --
   --           <condition id="4" text="F (C..." coverage="-">
   --              <src>
   --                 <line num="11"
   --                       column_begin="28"
   --                       src="F (C"/>
   --                 <line num="12"
   --                       src="                            and then D"/>
   --              </src>
   --
   --           </condition>
   --        </decision>
   --
   --
   --        <decision id="5" text="C..." coverage="-">
   --           <src>
   --              <line num="11"
   --                    column_begin="31"
   --                    src="C"/>
   --              <line num="12"
   --                    column_end="41"
   --                    src="                            and then D"/>
   --           </src>
   --
   --           <condition id="6" text="C" coverage="-">
   --              <src>
   --                 <line num="11"
   --                       column_begin="31"
   --                       column_end="32"
   --                       src="C"/>
   --              </src>
   --
   --           </condition>
   --
   --           <condition id="7" text="D" coverage="-">
   --              <src>
   --                 <line num="12"
   --                       column_begin="40"
   --                       column_end="41"
   --                       src="D"/>
   --              </src>
   --           </condition>
   --        </decision>
   --
   --        <message kind="warning"
   --                 SCO="SCO #3: CONDITION"
   --                 message="failed to show independent influence"/>
   --        <message kind="warning"
   --                 SCO="SCO #4: CONDITION"
   --                 message="failed to show independent influence"/>
   --        <message kind="error"
   --                 SCO="SCO #5: DECISION"
   --                 message="statement not covered"/>
   --
   --     </src_mapping>
   --
   --     <src_mapping coverage=".">
   --        # As said previously, this line could have been included in the
   --        # previous src_mapping.
   --        <src>
   --           <line num="12"
   --                 src="                               and then D))"/>
   --        </src>
   --     </src_mapping>
   --
   --     <src_mapping coverage="+">
   --        <src>
   --           <line num="13" src="      return 12;"/>
   --        </src>
   --
   --        <statement id="8" text="return 1..." coverage="+"/>
   --     </src_mapping>
   --
   --     <src_mapping>
   --        <src>
   --           <line num="13" src="   end if;"/>
   --        </src>
   --     </src_mapping>
   --
   --     <src_mapping coverage="+">
   --        <src>
   --           <line num="14" src="   Pack.Func; return 13;"/>
   --        </src>
   --
   --        <statement id="9" text="Pack.Fun..." coverage="+">
   --           <src>
   --              <line num="14"
   --                    column_begin="3"
   --                    column_end="12"
   --                    src="Pack.Func;"/>
   --           </src>
   --        </statement>
   --
   --        <statement id="9" text="return 1..." coverage="+">
   --           <src>
   --              <line num="14"
   --                    column_begin="14"
   --                    column_end="23"
   --                    src="return 13;"/>
   --           </src>
   --        </statement>
   --     </src_mapping>
   --
   --  </source>

   function To_Xml_String (S : String) return String;
   --  Return the string S with '>', '<' and '&' replaced by XML entities

   procedure Generate_Report (Context : Coverage.Context_Access);

end Annotations.Xml;
