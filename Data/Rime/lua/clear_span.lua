-- Keep the decoder's exact input span with each candidate. This is internal
-- metadata; the keyboard shows candidate text only.
return function(input, env)
  local index = 0
  for candidate in input:iter() do
    -- Sentence quality is zero in Rime; the phrase weight is the actual
    -- dictionary/language-model score used by the sentence search. The leading
    -- choice controls the confidence gate; at most nine scores also bound the
    -- auxiliary model's influence. Scrolling does no additional scoring.
    local phrase = index < 9 and candidate:get_genuine():to_phrase()
    local weight = phrase and phrase.weight or -1000000
    index = index + 1
    candidate.comment = (candidate.comment or "") .. "\t" .. tostring(candidate._end)
        .. "\t" .. tostring(weight)
    yield(candidate)
  end
end
