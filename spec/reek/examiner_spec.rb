require_relative '../spec_helper'
require_lib 'reek/examiner'
require_lib 'reek/logging_error_handler'

RSpec.shared_examples_for 'no smells found' do
  it 'is not smelly' do
    expect(examiner).not_to be_smelly
  end
  it 'finds no smells' do
    expect(examiner.smells.length).to eq(0)
  end
end

RSpec.shared_examples_for 'one smell found' do
  it 'is smelly' do
    expect(examiner).to be_smelly
  end

  it 'reports the smell' do
    expect(examiner.smells.length).to eq(1)
  end

  it 'reports the correct smell' do
    expect(examiner.smells[0].smell_type).to eq(expected_first_smell)
  end
end

RSpec.describe Reek::Examiner do
  context 'with a fragrant String' do
    let(:examiner) { described_class.new('def good() true; end') }

    it_behaves_like 'no smells found'
  end

  context 'with a smelly String' do
    let(:examiner) { described_class.new('def fine() y = 4; end') }
    let(:expected_first_smell) { 'UncommunicativeVariableName' }

    it_behaves_like 'one smell found'
  end

  context 'with a partially masked smelly File' do
    let(:configuration) { test_configuration_for(path) }
    let(:examiner) do
      described_class.new(SMELLY_FILE,
                          filter_by_smells: [],
                          configuration: configuration)
    end
    let(:path) { CONFIG_PATH.join('partial_mask.reek') }
    let(:expected_first_smell) { 'UncommunicativeVariableName' }

    it_behaves_like 'one smell found'
  end

  context 'with a fragrant File' do
    let(:examiner) { described_class.new(CLEAN_FILE) }

    it_behaves_like 'no smells found'
  end

  describe '.new' do
    context 'returns a proper Examiner' do
      let(:source) { 'class C; def f; end; end' }
      let(:examiner) do
        described_class.new(source)
      end

      it 'has been run on the given source' do
        expect(examiner.origin).to eq('string')
      end

      it 'has the right smells' do
        smells = examiner.smells
        expect(smells[0].message).to eq('has no descriptive comment')
        expect(smells[1].message).to eq("has the name 'f'")
        expect(smells[2].message).to eq("has the name 'C'")
      end

      it 'has the right smell count' do
        expect(examiner.smells_count).to eq(3)
      end
    end
  end

  describe '#smells' do
    it 'returns the detected smell warnings' do
      code     = 'def foo; bar.call_me(); bar.call_me(); end'
      examiner = described_class.new code, filter_by_smells: ['DuplicateMethodCall']

      smell = examiner.smells.first
      expect(smell).to be_a(Reek::SmellWarning)
      expect(smell.message).to eq("calls 'bar.call_me()' 2 times")
    end

    context 'source is empty' do
      let(:source) do
        <<-EOS
            # Just a comment
            # And another
        EOS
      end
      let(:examiner) do
        described_class.new(source)
      end

      it 'has no warnings' do
        expect(examiner.smells).to eq([])
      end
    end

    context 'with an incomprehensible source that causes the detectors to crash' do
      let(:source) { 'class C; def does_crash_reek; end; end' }

      let(:examiner) do
        detector_repository = instance_double 'Reek::DetectorRepository'
        allow(detector_repository).to receive(:examine) do
          raise ArgumentError, 'Looks like bad source'
        end
        class_double('Reek::DetectorRepository').as_stubbed_const
        allow(Reek::DetectorRepository).to receive(:eligible_smell_types)
        allow(Reek::DetectorRepository).to receive(:new).and_return detector_repository

        described_class.new source
      end

      it 'raises an incomprehensible source error' do
        expect { examiner.smells }.to raise_error Reek::Errors::IncomprehensibleSourceError
      end

      it 'explains the origin of the error' do
        origin = 'string'
        expect { examiner.smells }.to raise_error.with_message(/#{origin}/)
      end

      it 'explains what to do' do
        explanation = 'Please double check your Reek configuration'
        expect { examiner.smells }.to raise_error.with_message(/#{explanation}/)
      end

      it 'contains the original error message' do
        original = 'Looks like bad source'
        expect { examiner.smells }.to raise_error.with_message(/#{original}/)
      end
    end
  end

  context 'when the source causes the source buffer to crash' do
    let(:source) { 'I make the buffer crash' }

    before do
      buffer = double
      allow(buffer).to receive(:source=) { raise RuntimeError }
      allow(Parser::Source::Buffer).to receive(:new).and_return(buffer)
    end

    context 'if the error handler does not handle the error' do
      let(:examiner) { described_class.new(source) }

      it 'does not raise an error during initialization' do
        expect { examiner }.not_to raise_error
      end

      it 'raises an incomprehensible source error when asked for smells' do
        expect { examiner.smells }.to raise_error Reek::Errors::IncomprehensibleSourceError
      end
    end

    context 'if the error handler handles the error' do
      let(:handler) { instance_double(Reek::LoggingErrorHandler, handle: true) }
      let(:examiner) { described_class.new(source, error_handler: handler) }

      it 'does not raise an error when asked for smells' do
        expect { examiner.smells }.not_to raise_error
      end

      it 'passes the wrapped error to the handler' do
        examiner.smells
        expect(handler).to have_received(:handle).with(Reek::Errors::IncomprehensibleSourceError)
      end
    end
  end

  context 'with a source that triggers an encoding error' do
    let(:examiner) { described_class.new(source) }
    let(:source) do
      <<-SRC.strip_heredoc
      # encoding: US-ASCII
      puts 'こんにちは世界'
      SRC
    end

    it 'does not raise an error during initialization' do
      expect { examiner }.not_to raise_error
    end

    it 'raises an encoding error when asked for smells' do
      expect { examiner.smells }.to raise_error Reek::Errors::EncodingError
    end

    it 'explains the origin of the error' do
      message = "Source 'string' cannot be processed by Reek due to an encoding error in the source file."
      expect { examiner.smells }.to raise_error.with_message(/#{message}/)
    end
  end

  describe 'bad comment config' do
    let(:examiner) { described_class.new(source) }

    context 'unknown smell detector' do
      let(:source) do
        <<-EOS
          # :reek:DoesNotExist
          def alfa; end
        EOS
      end

      it 'raises a bad detector name error' do
        expect { examiner.smells }.to raise_error Reek::Errors::BadDetectorInCommentError
      end

      it 'explains the reason for the error' do
        message = "You are trying to configure an unknown smell detector 'DoesNotExist'"

        expect { examiner.smells }.to raise_error.with_message(/#{message}/)
      end

      it 'explains the origin of the error' do
        details = "The source is 'string' and the comment belongs "\
                  'to the expression starting in line 2.'

        expect { examiner.smells }.to raise_error.with_message(/#{details}/)
      end
    end

    context 'garbage in detector config' do
      let(:source) do
        <<-EOS
          # :reek:UncommunicativeMethodName { thats: a: bad: config }
          def alfa; end
        EOS
      end

      it 'raises a garbarge configuration error' do
        expect { examiner.smells }.to raise_error Reek::Errors::GarbageDetectorConfigurationInCommentError
      end

      it 'explains the reason for the error' do
        message = "Error: You are trying to configure the smell detector 'UncommunicativeMethodName'"

        expect { examiner.smells }.to raise_error.with_message(/#{message}/)
      end

      it 'explains the origin of the error' do
        details = "The source is 'string' and the comment belongs "\
                  'to the expression starting in line 2.'

        expect { examiner.smells }.to raise_error.with_message(/#{details}/)
      end
    end
  end
end
