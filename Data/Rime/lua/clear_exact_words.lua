-- The strict channel offers dictionary phrases, never synthesized sentences.
-- Filter explicitly even on Rime builds that still synthesize with max_sentences=0.
return function(input, env)
  for candidate in input:iter() do
    if candidate.type ~= "sentence" then
      yield(candidate)
    end
  end
end
