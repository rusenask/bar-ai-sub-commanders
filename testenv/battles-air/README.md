# Air strike specs (scenario battle, `role air`)

Our planes go to an Air Force sub-commander; theirs is a base laid out with offsets (`them <unit> <n> <dx>
<dz>`): an economy with and without anti-air. A strike that is called off (nobody loses anything) counts
as even (efficiency 1).

    SCENARIO=battle BATTLES=testenv/battles-air testenv/force-batch.sh 32
    uvx --with lightning-sdk python testenv/sandbox/batch.py 32 --scenario battle --battles testenv/battles-air ...
