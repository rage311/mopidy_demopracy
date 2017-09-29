#!/usr/bin/env perl
use 5.024;
use Mojo::JSON qw(to_json);

  my $tracklist_example = [
    {
      artist_string => 'Fall Out Boy',
      title         => 'Some Song',
      album_title   => 'Some Album',
      tlid          => 902,
      votes         => [
        {
          name  => 'matt',
          ip    => '10.0.0.31',
          value => -1,
          time  => 1506712631,
        },
        {
          name  => 'bryan',
          ip    => '10.0.0.32',
          value => -1,
          time  => 1506712630,
        },
      ],
    },

    {
      artist_string => 'Kimbra',
      title         => 'Miracle',
      album_title   => 'The Golden Echo',
      tlid          => 903,
      votes         => [
        {
          name  => 'matt',
          ip    => '10.0.0.31',
          value => 1,
          time  => 1506712627,
        },
        {
          name  => 'bryan',
          ip    => '10.0.0.32',
          value => 1,
          time  => 1506712625,
        },
      ],
    },

    {
      artist_string => 'Kimbra, Bilal', # calculated
      title         => 'Everlovin Ya',
      album_title   => 'The Golden Echo',
      tlid          => 904,
      votes         => [
        {
          name  => 'matt',
          ip    => '10.0.0.31',
          value => 1,
          time  => 1506712633,
        },
        {
          name  => 'bryan',
          ip    => '10.0.0.32',
          value => -1,
          time  => 1506712635,
        },
      ],
    },

    {
      artist_string => 'Every Time I Die',
      title         => 'Decayin\' with the Boys',
      album_title   => 'From Parts Unknown',
      tlid          => 905,
      votes         => [ ],
    },
  ];

say to_json($tracklist_example);

